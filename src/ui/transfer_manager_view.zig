//! Frozen UI_V3 transfer views. The application owns IO and native windows. Closing
//! these views never changes jobs; snapshots and displayed strings are copied.
const std = @import("std");
const ui = @import("ui");
const backend = @import("../transfer/manager.zig");
const identity = @import("../host/identity.zig");
const S = @import("transfer_styles.zig");

pub const Action = enum { pause, resume_transfer, cancel, retry, promote, reveal, resolve_conflict };
pub const Callbacks = struct {
    context: *anyopaque,
    action: *const fn (*anyopaque, backend.JobId, Action) void,
    can_reveal: ?*const fn (*anyopaque, backend.JobId) bool = null,
    open_sftp: ?*const fn (*anyopaque) void = null,
    open_manager: ?*const fn (*anyopaque, Scope) void = null,
    scope_choices: ?*const fn (*anyopaque, std.mem.Allocator) anyerror![]const ScopeChoice = null,
    owner_label: ?*const fn (*anyopaque, backend.JobId) []const u8 = null,
    metadata: ?*const fn (*anyopaque, backend.JobId) []const u8 = null,
    owner: ?*const fn (*anyopaque, backend.JobId) ?identity.SessionHandle = null,
};
pub const Statistics = struct { window_chunks: u8, chunk_kb: u16, today_bytes: ?u64 = null };
pub const Presentation = enum { window, global_popover, session_popover, session_tray };
pub const Options = struct { presentation: Presentation = .window, fill_window: bool = false };
pub const Target = struct { job: backend.JobId, attempt: u32, owner: ?identity.SessionHandle };
pub const TaskAction = enum { pause, resume_transfer, cancel, retry, reveal, new_draft, resolve_conflict };
pub const WindowAction = enum { minimize, zoom, close };
pub const Phase = enum { queued, running, retry_wait, pausing, paused, conflict, verifying, succeeded, skipped, failed, checksum_failed, cancelling, cancelled, cleanup_unknown };
pub const Scope = union(enum) {
    all,
    session: identity.SessionHandle,
    sessions: struct { members: []const identity.SessionHandle, revision: u64 },
};
pub const ScopeChoice = struct { label: []const u8, scope: Scope };
pub const Task = struct {
    target: Target,
    direction: backend.Direction,
    name: []const u8,
    owner_label: []const u8 = "",
    local_path: []const u8 = "",
    remote_path: []const u8 = "",
    route: []const u8 = "",
    phase: Phase,
    done_bytes: u64 = 0,
    total_bytes: ?u64 = null,
    speed_bps: u64 = 0,
    status_detail: []const u8 = "",
    options: []const u8 = "",
    events: []const u8 = "",
    event_summary: []const u8 = "",
    can_resume: bool = true,
    can_reveal: bool = true,
};
pub const Snapshot = struct {
    revision: u64,
    rows: []const Task,
    scope: Scope = .all,
    choices: []const ScopeChoice = &.{},
    scope_label: []const u8 = "全部会话",
    notice: []const u8 = "",
};
pub const Hooks = struct {
    context: *anyopaque,
    action: ?*const fn (*anyopaque, Target, TaskAction) anyerror!void = null,
    /// Host confirms destructive actions against this frozen selection.
    batch: ?*const fn (*anyopaque, []const Target, TaskAction) anyerror!void = null,
    window: ?*const fn (*anyopaque, WindowAction) anyerror!void = null,
    scope_changed: ?*const fn (*anyopaque, Scope) void = null,
    new_transfer: ?*const fn (*anyopaque) void = null,
    open_manager: ?*const fn (*anyopaque, Scope) void = null,
};
pub const Filter = enum { all, active, waiting, paused, failed, ended };
pub const Counts = struct { active: usize = 0, waiting: usize = 0, paused: usize = 0, failed: usize = 0, ended: usize = 0, speed_bps: u64 = 0 };

fn category(phase: Phase) Filter {
    return switch (phase) {
        .running, .verifying, .pausing, .cancelling, .cleanup_unknown => .active,
        .queued, .retry_wait, .conflict => .waiting,
        .paused => .paused,
        .failed, .checksum_failed => .failed,
        .succeeded, .skipped, .cancelled => .ended,
    };
}
pub fn phaseLabel(phase: Phase) []const u8 {
    return switch (phase) {
        .queued => "排队中",
        .running => "传输中",
        .retry_wait => "等待重试",
        .pausing => "停止请求中",
        .paused => "已暂停",
        .conflict => "等待处理同名文件",
        .verifying => "正在校验",
        .succeeded => "已完成",
        .skipped => "已跳过",
        .failed => "传输失败",
        .checksum_failed => "校验失败",
        .cancelling => "清理中",
        .cancelled => "已取消",
        .cleanup_unknown => "清理结果未知",
    };
}
fn failureLabel(failure: backend.Failure) []const u8 {
    return switch (failure) {
        .invalid_request => "请求参数不可用",
        .not_found => "文件不存在",
        .permission_denied => "没有文件访问权限",
        .conflict => "文件冲突或内容已变化",
        .connection => "连接不可用",
        .timeout => "连接超时",
        .checksum => "文件校验未通过",
        .protocol => "传输状态异常",
        .io => "文件读写失败",
    };
}
pub fn allows(phase: Phase, action: TaskAction) bool {
    return switch (action) {
        .pause => phase == .running or phase == .queued or phase == .retry_wait,
        .resume_transfer => phase == .paused,
        .retry => phase == .failed,
        .new_draft => phase == .cancelled or phase == .checksum_failed,
        .resolve_conflict => phase == .conflict,
        .reveal => phase == .succeeded,
        .cancel => phase == .running or phase == .queued or phase == .retry_wait or phase == .pausing or phase == .paused or phase == .conflict or phase == .verifying,
    };
}
pub fn belongs(scope: Scope, owner: ?identity.SessionHandle) bool {
    return switch (scope) {
        .all => true,
        .session => |handle| if (owner) |value| handle.eql(value) else false,
        .sessions => |group| blk: {
            const actual = owner orelse break :blk false;
            for (group.members) |member| if (member.eql(actual)) break :blk true;
            break :blk false;
        },
    };
}
fn same(a: Target, b: Target) bool {
    return std.meta.eql(a, b);
}
pub fn scopeEql(a: Scope, b: Scope) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .all => true,
        .session => |owner| owner.eql(b.session),
        .sessions => |group| blk: {
            if (group.revision != b.sessions.revision or group.members.len != b.sessions.members.len) break :blk false;
            for (group.members, b.sessions.members) |left, right| if (!left.eql(right)) break :blk false;
            break :blk true;
        },
    };
}
fn copyScope(a: std.mem.Allocator, scope: Scope) !Scope {
    return switch (scope) {
        .sessions => |group| .{ .sessions = .{ .members = try a.dupe(identity.SessionHandle, group.members), .revision = group.revision } },
        else => scope,
    };
}
fn taskEql(a: Task, b: Task) bool {
    if (!same(a.target, b.target) or a.direction != b.direction or a.phase != b.phase or
        a.done_bytes != b.done_bytes or a.total_bytes != b.total_bytes or a.speed_bps != b.speed_bps or
        a.can_resume != b.can_resume or a.can_reveal != b.can_reveal) return false;
    inline for (.{ "name", "owner_label", "local_path", "remote_path", "route", "status_detail", "options", "events", "event_summary" }) |field| {
        if (!std.mem.eql(u8, @field(a, field), @field(b, field))) return false;
    }
    return true;
}
/// Revisions order snapshots; only displayed facts require new row ownership.
fn snapshotEql(a: Snapshot, b: Snapshot) bool {
    if (!scopeEql(a.scope, b.scope) or !std.mem.eql(u8, a.scope_label, b.scope_label) or
        !std.mem.eql(u8, a.notice, b.notice) or a.rows.len != b.rows.len or a.choices.len != b.choices.len) return false;
    for (a.rows, b.rows) |left, right| if (!taskEql(left, right)) return false;
    for (a.choices, b.choices) |left, right| {
        if (!scopeEql(left.scope, right.scope) or !std.mem.eql(u8, left.label, right.label)) return false;
    }
    return true;
}
const Owned = struct {
    arena: std.heap.ArenaAllocator,
    value: Snapshot,
    fn init(allocator: std.mem.Allocator, value: Snapshot) !Owned {
        if (value.revision == 0) return error.InvalidRevision;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var copy = value;
        copy.scope = try copyScope(a, value.scope);
        copy.scope_label = try a.dupe(u8, value.scope_label);
        copy.notice = try a.dupe(u8, value.notice);
        const rows = try a.dupe(Task, value.rows);
        for (rows, 0..) |*task, i| {
            if (task.target.job == 0) return error.InvalidJob;
            if (task.target.owner) |owner| if (@backingInt(owner.session_id) == 0 or owner.generation == 0) return error.InvalidOwner;
            for (rows[0..i]) |previous| if (previous.target.job == task.target.job) return error.DuplicateJob;
            inline for (.{ "name", "owner_label", "local_path", "remote_path", "route", "status_detail", "options", "events", "event_summary" }) |field| @field(task, field) = try a.dupe(u8, @field(task, field));
        }
        copy.rows = rows;
        const choices = try a.dupe(ScopeChoice, value.choices);
        for (choices) |*choice| {
            choice.label = try a.dupe(u8, choice.label);
            choice.scope = try copyScope(a, choice.scope);
        }
        copy.choices = choices;
        return .{ .arena = arena, .value = copy };
    }
};

pub fn mountProjection(cx: *ui.Cx, scope: *ui.Scope, options: Options, hooks: Hooks) !*Panel {
    return Panel.mountProjection(cx, scope, options, hooks);
}
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, manager: *backend.Manager, callbacks: Callbacks) !*Panel {
    const panel = try mountProjection(cx, scope, .{ .presentation = .session_popover }, .{ .context = callbacks.context, .new_transfer = callbacks.open_sftp, .open_manager = callbacks.open_manager });
    panel.manager = manager;
    panel.callbacks = callbacks;
    return panel;
}
/// Host appends root below its dual-pane file workspace and sets selected_scope
/// to the original owner, refreshes, then calls show(). The panel never derives authority from focus.
pub fn mountSessionTray(cx: *ui.Cx, scope: *ui.Scope, manager: *backend.Manager, callbacks: Callbacks) !*Panel {
    const panel = try mountProjection(cx, scope, .{ .presentation = .session_tray }, .{ .context = callbacks.context, .open_manager = callbacks.open_manager });
    panel.root.meta.ownership.meta.test_id = "transfer.session.tray";
    panel.manager = manager;
    panel.callbacks = callbacks;
    return panel;
}
/// The titlebar entry uses the global layout inside the current window.
/// Its close button only hides this view; it owns no native window or jobs.
pub fn mountGlobalPopover(cx: *ui.Cx, scope: *ui.Scope, manager: *backend.Manager, callbacks: Callbacks) !*Panel {
    const panel = try mountProjection(cx, scope, .{ .presentation = .global_popover }, .{ .context = callbacks.context });
    panel.manager = manager;
    panel.callbacks = callbacks;
    return panel;
}
pub fn mountWindow(cx: *ui.Cx, scope: *ui.Scope, manager: *backend.Manager, callbacks: Callbacks) !*Panel {
    const panel = try mountProjection(cx, scope, .{ .presentation = .window, .fill_window = true }, .{ .context = callbacks.context });
    panel.manager = manager;
    panel.callbacks = callbacks;
    return panel;
}

// A short leave grace lets the pointer cross the tooltip's 8px gap.
const DetailHover = struct {
    cx: *ui.Cx,
    close: ?ui.Handler(void),
    show: ?ui.Handler(void),
    deadline: ?i128 = null,
    fn enter(self: *DetailHover) void { self.deadline = null; }
    fn triggerEnter(self: *DetailHover) void { self.enter(); if (self.show) |show| show.invoke(); }
    fn leave(self: *DetailHover) void {
        self.deadline = @import("../platform/realtime.zig").monotonicNs() + 250 * std.time.ns_per_ms;
        self.cx.scheduleRedrawAfterNs(250 * std.time.ns_per_ms);
    }
    fn tick(node: *ui.Node) void {
        const self: *DetailHover = @ptrCast(@alignCast(node.meta.ownership.debug_slots.state_ptrs[0].?));
        if (self.deadline) |deadline| {
            const now = @import("../platform/realtime.zig").monotonicNs();
            if (now >= deadline) { self.deadline = null; if (self.close) |close| close.invoke(); }
            else self.cx.scheduleRedrawAfterNs(@intCast(deadline - now));
        }
    }
};

const Control = struct {
    panel: *Panel,
    target: ?Target = null,
    action: ?TaskAction = null,
    window: ?WindowAction = null,
    choice: ?usize = null,
    menu_open: ?*ui.Signal(bool) = null,
    state_filter: ?Filter = null,
    kind: enum { action, detail, events, copy_path, copy_local_path, window, choice, search, filter, new_transfer, batch, batch_pause, batch_resume, batch_cancel, all_tasks, scope_tasks, state_filter } = .action,
    fn run(self: *Control) void {
        const p = self.panel;
        if (self.menu_open) |open| open.set(false);
        p.in_action = true;
        defer p.in_action = false;
        switch (self.kind) {
            .state_filter => p.setFilter(self.state_filter.?),
            .action => p.perform(self.target.?, self.action.?) catch |err| p.fail(err),
            .events => {
                const task_ = p.task(self.target.?) orelse return;
                if (p.event_view == null) p.event_view = @import("transfer_events_view.zig").View.mount(p.cx, p.scope) catch |err| {
                    p.fail(err);
                    return;
                };
                p.event_view.?.show(task_.target.job, task_.events) catch |err| p.fail(err);
            },
            .copy_path, .copy_local_path => {
                const task_ = p.task(self.target.?) orelse return;
                if (!ui.platform_services.clipboardSetText(p.cx.system_sdk, if (self.kind == .copy_local_path) task_.local_path else task_.remote_path)) p.fail(error.ClipboardUnavailable);
            },
            .detail => {
                if (p.task(self.target.?) == null) return;
                p.expanded = if (p.expanded != null and same(p.expanded.?, self.target.?) and self.kind == .detail) null else self.target;
                p.events_open = self.kind == .events;
                p.invalidate();
            },
            .window => {
                if (p.options.presentation == .window) {
                    if (p.hooks.window) |call| call(p.window_context orelse p.hooks.context, self.window.?) catch |err| {
                        p.fail(err);
                        return;
                    };
                }
                if (self.window == .close) p.hide();
            },
            .choice => {
                const source = p.source orelse return;
                if (self.choice.? >= source.value.choices.len) return;
                p.scope_choice = self.choice;
                p.selected_scope = source.value.choices[self.choice.?].scope;
                p.scopes_dirty = true;
                if (p.hooks.scope_changed) |call| call(p.hooks.context, p.selected_scope);
                p.invalidate();
            },
            .search => {
                p.search_visible = !p.search_visible;
                p.invalidate();
            },
            .filter => {
                p.filter_visible = !p.filter_visible;
                p.invalidate();
            },
            .new_transfer => if (p.hooks.new_transfer) |call| call(p.hooks.context),
            .all_tasks, .scope_tasks => {
                if (p.hooks.open_manager) |call| call(p.hooks.context, if (self.kind == .all_tasks) .all else p.selected_scope) else if (self.kind == .all_tasks) {
                    p.selected_scope = .all;
                    p.scope_choice = 0;
                    p.scopes_dirty = true;
                    p.invalidate();
                }
            },
            .batch => {
                p.scopes_dirty = true;
                p.batch_visible = !p.batch_visible;
                if (!p.batch_visible) p.selection.clearRetainingCapacity();
                p.invalidate();
            },
            .batch_pause => p.performBatch(.pause) catch |err| p.fail(err),
            .batch_resume => p.performBatch(.resume_transfer) catch |err| p.fail(err),
            .batch_cancel => p.performBatch(.cancel) catch |err| p.fail(err),
        }
    }
    fn checked(self: *Control, value: bool) void {
        const p = self.panel;
        const target = self.target.?;
        if (p.task(target) == null) return;
        if (value) {
            for (p.selection.items) |selected| if (same(selected, target)) return;
            p.selection.append(p.cx.allocator, target) catch |err| {
                p.fail(err);
                return;
            };
        } else {
            for (p.selection.items, 0..) |selected, i| if (same(selected, target)) {
                _ = p.selection.orderedRemove(i);
                break;
            };
        }
        p.batch_visible = true;
        p.invalidate();
    }
};

pub const Panel = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    root: *ui.Node,
    options: Options,
    hooks: Hooks,
    manager: ?*backend.Manager = null,
    callbacks: ?Callbacks = null,
    source: ?Owned = null,
    pending_source: ?Owned = null,
    visible: std.ArrayList(usize) = .empty,
    selection: std.ArrayList(Target) = .empty,
    selected_scope: Scope = .all,
    scope_choice: ?usize = null,
    filter: Filter = .all,
    direction_filter: ?backend.Direction = null,
    tray_requested_show: bool = false,
    counts: Counts = .{},
    expanded: ?Target = null,
    tray_layout_width: f32 = 0,
    metadata_layout_width: f32 = 0,
    owner_column_width: f32 = 106,
    events_open: bool = false,
    event_view: ?*@import("transfer_events_view.zig").View = null,
    batch_visible: bool = false,
    search_visible: bool = false,
    filter_visible: bool = false,
    dirty: bool = false,
    in_action: bool = false,
    anchor_id: ?u32 = null,
    pending_refresh: ?struct { now: u64, stats: Statistics } = null,
    revision: u64 = 0,
    window_disabled: *ui.Signal(bool),
    window_context: ?*anyopaque = null,
    paint_colors: S.theme.Colors,
    scopes_dirty: bool = false,
    head: *ui.Node,
    heading_title: *ui.Node,
    foot: *ui.Node,
    scope_row: *ui.Node,
    scope_scope: ?*ui.Scope = null,
    v3_filters: ?*ui.Node = null,
    v3_filter_labels: [3]?*ui.Node = @splat(null),
    counts_row: *ui.Node,
    tools_row: *ui.Node,
    counts_labels: [5]*ui.Node,
    title_badge: *ui.Node,
    notice: *ui.Node,
    footer_label: *ui.Node,
    footer_rate: *ui.Node,
    empty: *ui.Node,
    empty_container: *ui.Node = undefined,
    empty_description: ?*ui.Node = null,
    failure: *ui.Node,
    search: *ui.Signal([]const u8),
    search_node: *ui.Node,
    filters_node: *ui.Node,
    batch_row: *ui.Node,
    batch_label: *ui.Node,
    list: struct { container: *ui.Node, content: *ui.Node, state: *ui.widgets.scroll_area.ScrollState },
    virtual: *ui.widgets.VirtualListState,
    samples: [8]u64 = @splat(0),
    sample_count: usize = 0,
    last_sample_ms: ?u64 = null,

    pub fn mountProjection(cx: *ui.Cx, scope: *ui.Scope, options: Options, hooks: Hooks) !*Panel {
        const p = try cx.allocator.create(Panel);
        p.* = .{ .cx = cx, .scope = scope, .root = undefined, .options = options, .hooks = hooks, .window_disabled = try scope.createSignal(bool, hooks.window == null), .paint_colors = S.theme.current(), .head = undefined, .heading_title = undefined, .foot = undefined, .scope_row = undefined, .counts_row = undefined, .tools_row = undefined, .counts_labels = undefined, .title_badge = undefined, .notice = undefined, .footer_label = undefined, .footer_rate = undefined, .empty = undefined, .failure = undefined, .search = try scope.createText("", .{}), .search_node = undefined, .filters_node = undefined, .batch_row = undefined, .batch_label = undefined, .list = undefined, .virtual = undefined };
        try scope.onCleanup(Panel, p, cleanup);
        const tray = options.presentation == .session_tray;
        const window = !tray;
        const native_window = options.presentation == .window;
        p.root = try ui.box(cx, if (tray) S.sessionTray() else S.panel(true), .{});
        p.root.meta.ownership.meta.test_id = "transfer.manager";
        if (!native_window and !tray) p.root.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .top = .{ .px = 46 }, .right = .{ .px = 14 } }, .z_index = 50 });
        p.root.setDisplay(.none);
        p.head = try ui.box(cx, S.row(if (tray) 28 else 30, 6), .{});
        p.head.meta.ownership.meta.test_id = "transfer.header";
        try p.root.appendChild(cx.allocator, p.head);
        if (!tray) {
            try p.root.insertChildBefore(cx.allocator, try ui.boxStyled(cx, S.topFade, .{}), p.head);
            try p.root.appendChild(cx.allocator, try ui.boxStyled(cx, S.grip, .{}));
        }
        if (!tray) try p.head.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("arrow-down-up").?, S.theme.current().accent_ink, S.icon(18)));
        const heading_title = try p.label(p.head, if (tray) "当前会话传输" else "传输任务", if (tray) 12 else 13, 700, false);
        p.heading_title = heading_title;
        heading_title.meta.ownership.meta.test_id = "transfer.header.title";
        if (!native_window) if (heading_title.getText()) |old| {
            var props = old;
            props.line_height = 20.0 / 13.0;
            heading_title.setText(props);
        };
        heading_title.setStyleInline(cx.allocator, if (tray) S.flexibleLabel() else S.label(72));
        if (!tray) try p.head.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.lock_keyhole, S.theme.current().fg_2, S.icon(12)));
        p.title_badge = try p.label(p.head, "", 10.5, 400, true);
        p.title_badge.setDisplay(if (tray) .none else .flex);
        p.title_badge.setStyleInline(cx.allocator, .{ .height = .{ .px = 22 }, .padding = .{ .left = 8, .right = 8 }, .background = S.theme.current().surface_2, .border = .{ .radius = 6 } });
        if (!tray) try p.head.appendChild(cx.allocator, try ui.spacer(cx));
        if (native_window) {
            _ = try p.button(p.head, scope, "最小化传输窗口", "transfer.window.minimize", "minus", .{ .panel = p, .kind = .window, .window = .minimize }, p.window_disabled, 22);
            _ = try p.button(p.head, scope, "缩放传输窗口", "transfer.window.zoom", "maximize-2", .{ .panel = p, .kind = .window, .window = .zoom }, p.window_disabled, 22);
        }
        if (tray) {
            _ = try p.button(p.head, scope, "管理任务", "transfer.batch", "list-checks", .{ .panel = p, .kind = .batch }, false, 24);
        } else _ = try p.button(p.head, scope, if (native_window) "收起传输" else "关闭浮卡", "transfer.window.close", "x", .{ .panel = p, .kind = .window, .window = .close }, false, if (native_window) 22 else 24);
        try p.root.appendChild(cx.allocator, try ui.box(cx, S.gap(if (tray) 6 else 9), .{}));
        p.scope_row = try ui.box(cx, S.row(@import("workspace_tab_styles.zig").height, 4), .{});
        try p.root.appendChild(cx.allocator, p.scope_row);
        p.counts_row = try ui.box(cx, S.row(28, 6), .{});
        p.counts_row.meta.ownership.meta.test_id = "transfer.states.toolbar";
        try p.root.appendChild(cx.allocator, p.counts_row);
        for (&p.counts_labels, 0..) |*label_, i| {
            const box = try ui.box(cx, S.badge(if (i == 0) 84 else 74, countColor(i)), .{});
            label_.* = try p.label(box, "", 10, 500, true);
            try p.counts_row.appendChild(cx.allocator, box);
        }
        try p.counts_row.appendChild(cx.allocator, try ui.spacer(cx));
        p.tools_row = try ui.box(cx, .{ .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 }, .{});
        try p.counts_row.appendChild(cx.allocator, p.tools_row);
        p.search_node = try ui.widgets.Input(.{ .value = p.search, .placeholder = "搜索文件名、路径或会话", .on_change = cx.on(Panel, p, searchChanged) }).mount(scope, cx);
        p.search_node.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 30 }, .flex_shrink = 0 });
        p.search_node.meta.ownership.meta.test_id = "transfer.search";
        try p.root.appendChild(cx.allocator, p.search_node);
        const filter_result = try ui.widgets.Select(.{ .options = &[_]ui.widgets.SelectOption{
            .{ .value = "all", .label = "全部状态" },
            .{ .value = "active", .label = "进行中" },
            .{ .value = "waiting", .label = "等待" },
            .{ .value = "paused", .label = "暂停" },
            .{ .value = "failed", .label = "失败" },
            .{ .value = "ended", .label = "结束" },
        }, .placeholder = "全部状态", .width = 120, .on_change = cx.on(Panel, p, filterChanged) }).mount(scope, cx);
        p.filters_node = filter_result.wrapper;
        p.filters_node.meta.ownership.meta.test_id = "transfer.filter";
        try p.root.appendChild(cx.allocator, p.filters_node);
        const notice_row = try ui.box(cx, S.row(30, 6), .{});
        notice_row.meta.ownership.meta.test_id = "transfer.notice";
        notice_row.setDisplay(.none);
        try notice_row.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.lock_keyhole, S.theme.current().fg_2, S.icon(14)));
        p.notice = try p.label(notice_row, "", 10.5, 400, true);
        p.notice.setStyleInline(cx.allocator, S.flexibleLabel());
        try p.root.appendChild(cx.allocator, notice_row);
        if (window) {
            p.scope_row.setStyleInline(cx.allocator, .{ .margin = .{ .bottom = 6 } });
            p.counts_row.setStyleInline(cx.allocator, .{ .margin = .{ .bottom = 6 } });
            notice_row.setStyleInline(cx.allocator, .{ .margin = .{ .bottom = 6 } });
        } else {
            p.scope_row.setDisplay(.none);
            p.counts_row.setDisplay(.none);
            notice_row.setDisplay(.none);
        }
        p.search_node.setDisplay(.none);
        p.filters_node.setDisplay(.none);
        p.failure = try p.label(p.root, "", 10.5, 400, true);
        p.failure.setStyleInline(cx.allocator, S.errorLine());
        p.failure.setDisplay(.none);
        const empty_state = try ui.box(cx, S.emptyState(), .{});
        p.empty_container = empty_state;
        empty_state.meta.ownership.meta.test_id = "transfer.empty";
        try p.root.appendChild(cx.allocator, empty_state);
        if (!tray) {
            try empty_state.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.folder_open, S.theme.current().fg_2, S.icon(18)));
            p.empty = try p.label(empty_state, "", 12, 500, false);
        } else {
            const icon_ = try ui.iconTint(cx, ui.icons.arrow_down_up, S.theme.current().fg_2, S.icon(24));
            icon_.meta.ownership.meta.test_id = "transfer.empty.icon";
            try empty_state.appendChild(cx.allocator, icon_);
            const text_column = try ui.box(cx, .{ .width = .fill(), .flex = 1, .min_width = 0, .direction = .column, .gap = 3 }, .{});
            text_column.meta.ownership.meta.test_id = "transfer.empty.text";
            try empty_state.appendChild(cx.allocator, text_column);
            p.empty = try p.label(text_column, "", 12, 600, false);
            p.empty.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 18 }, .flex_shrink = 0 });
            if (p.empty.getText()) |old| {
                var props = old;
                props.line_height = 1.5;
                p.empty.setText(props);
            }
            const description = try p.label(text_column, if (options.presentation == .global_popover or window) "从文件工作区或 @up / @dl 开始。" else "选择文件后上传或下载。", 11, 400, true);
            description.meta.ownership.meta.test_id = "transfer.empty.description";
            description.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 16 }, .flex_shrink = 0 });
            if (description.getText()) |old| {
                var props = old;
                props.line_height = 16.0 / 11.0;
                description.setText(props);
            }
            p.empty_description = description;
        }
        p.empty.meta.ownership.meta.test_id = "transfer.empty.title";
        empty_state.setDisplay(.none);
        p.batch_row = try ui.box(cx, S.row(30, 6), .{});
        p.batch_label = try p.label(p.batch_row, "", 11, 400, true);
        p.batch_label.setStyleInline(cx.allocator, S.flexibleLabel());
        _ = try p.button(p.batch_row, scope, "暂停所选任务", "transfer.batch.pause", "pause", .{ .panel = p, .kind = .batch_pause }, hooks.batch == null, 24);
        _ = try p.button(p.batch_row, scope, "恢复所选任务", "transfer.batch.resume", "play", .{ .panel = p, .kind = .batch_resume }, hooks.batch == null, 24);
        _ = try p.button(p.batch_row, scope, "取消所选任务", "transfer.batch.cancel", "x", .{ .panel = p, .kind = .batch_cancel }, hooks.batch == null, 24);
        p.batch_row.setDisplay(.none);
        try p.root.appendChild(cx.allocator, p.batch_row);
        const list = try ui.widgets.VirtualList(.{ .item_count = @as(usize, 0), .item_height = S.row_pitch, .height = if (window) @as(f32, 360) else @as(f32, 214), .overscan = 1, .item_height_fn = itemHeight, .item_height_context = p, .item_label_fn = itemLabel, .item_label_context = p }).mountWithContext(scope, cx, p, null, renderItem);
        p.virtual = list.state;
        p.list = .{ .container = list.container, .content = list.state.content_node, .state = list.state.scroll_state };
        list.container.setStyleInline(cx.allocator, S.viewport());
        p.list.content.style.padding.right = if (tray) 0 else 14;
        try p.root.appendChild(cx.allocator, list.container);
        try p.root.appendChild(cx.allocator, try ui.box(cx, S.gap(if (tray) 0 else 6), .{}));
        p.foot = try ui.box(cx, if (native_window or window) S.row(32, 6) else S.v3Footer(), .{});
        try p.root.appendChild(cx.allocator, p.foot);
        p.footer_label = try p.label(p.foot, "", 10.5, 400, true);
        p.footer_label.setStyleInline(cx.allocator, .{ .width = .{ .px = 210 }, .min_width = 0, .overflow = .hidden, .flex_shrink = 1 });
        p.footer_rate = try p.label(p.foot, "", 10.5, 400, true);
        p.footer_rate.setStyleInline(cx.allocator, S.flexibleLabel());
        try cx.addAfterLayoutHook(p, afterLayout);
        return p;
    }

    fn cleanup(self: *Panel) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.source) |*source| source.arena.deinit();
        if (self.pending_source) |*source| source.arena.deinit();
        self.visible.deinit(self.cx.allocator);
        self.selection.deinit(self.cx.allocator);
        self.cx.allocator.destroy(self);
    }
    fn label(self: *Panel, parent: *ui.Node, value: []const u8, size: f32, weight: u16, secondary: bool) !*ui.Node {
        const node = try ui.text(self.cx, "", S.text(size, weight, secondary));
        try node.setTextContent(self.cx.allocator, value);
        try parent.appendChild(self.cx.allocator, node);
        return node;
    }
    fn button(self: *Panel, parent: *ui.Node, scope: *ui.Scope, label_: []const u8, test_id: []const u8, icon: []const u8, control: Control, disabled: anytype, size: f32) !*ui.Node {
        const state = try scope.createState(Control, control);
        const owned_label = try scope.createText(label_, .{});
        const node = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.get(icon), .icon_size = if (size <= 24) @as(f32, 14) else 16, .a11y_label = owned_label, .base_style = S.action(size), .disabled = disabled, .on_click = self.cx.on(Control, state, Control.run) }).mount(scope, self.cx);
        node.meta.ownership.meta.test_id = test_id;
        try parent.appendChild(self.cx.allocator, node);
        return node;
    }
    pub fn update(self: *Panel, snapshot: Snapshot) !void {
        if (self.pending_source) |pending| if (snapshot.revision <= pending.value.revision) return;
        if (self.source) |source| if (snapshot.revision <= source.value.revision) return;
        if (self.pending_source) |*pending| {
            if (snapshotEql(pending.value, snapshot)) {
                pending.value.revision = snapshot.revision;
                if (!self.in_action) try self.flush();
                return;
            }
        } else if (self.source) |*source| {
            if (snapshotEql(source.value, snapshot)) {
                source.value.revision = snapshot.revision;
                self.revision = snapshot.revision;
                if (self.dirty and !self.in_action) try self.flush();
                return;
            }
        }
        const owned = try Owned.init(self.cx.allocator, snapshot);
        if (self.pending_source) |*old| old.arena.deinit();
        self.pending_source = owned;
        self.invalidate();
        if (!self.in_action) try self.flush();
    }
    pub fn flush(self: *Panel) !void {
        if (self.in_action) return;
        var retired_source: ?Owned = null;
        var rows_reset = false;
        defer if (retired_source) |*old| {
            // Allocation failures must not free strings still borrowed by old
            // row scopes. The normal path clears the pool once at its new count.
            if (!rows_reset) ui.widgets.virtual_list.updateItemCount(self.virtual, 0);
            old.arena.deinit();
        };
        if (self.pending_source) |next| {
            const same_scope = scopeEql(self.selected_scope, next.value.scope);
            retired_source = self.source;
            self.source = next;
            self.pending_source = null;
            self.selected_scope = next.value.scope;
            self.scope_choice = null;
            self.revision = next.value.revision;
            if (!same_scope) ui.widgets.scroll_area.setScrollY(self.list.state, self.list.content, 0);
            try self.renderScopes();
        }
        if (!self.dirty) return;
        self.dirty = false;
        const source = self.source orelse return;
        if (self.scopes_dirty) {
            self.scopes_dirty = false;
            try self.renderScopes();
        }
        self.visible.clearRetainingCapacity();
        self.counts = .{};
        const query = self.search.peek();
        for (source.value.rows, 0..) |task_, i| {
            if (!belongs(self.selected_scope, task_.target.owner)) continue;
            if (self.direction_filter) |direction| if (task_.direction != direction) continue;
            const kind = category(task_.phase);
            switch (kind) {
                .active => self.counts.active += 1,
                .waiting => self.counts.waiting += 1,
                .paused => self.counts.paused += 1,
                .failed => self.counts.failed += 1,
                .ended => self.counts.ended += 1,
                .all => unreachable,
            }
            if (task_.phase == .running) self.counts.speed_bps +|= task_.speed_bps;
            if (self.filter != .all and self.filter != kind) continue;
            if (query.len > 0 and !contains(task_.name, query) and !contains(task_.local_path, query) and !contains(task_.remote_path, query) and !contains(task_.owner_label, query)) continue;
            try self.visible.append(self.cx.allocator, i);
        }
        var selected_index: usize = 0;
        while (selected_index < self.selection.items.len) {
            var retained = false;
            for (self.visible.items) |i| if (same(source.value.rows[i].target, self.selection.items[selected_index])) {
                retained = true;
                break;
            };
            if (retained) selected_index += 1 else _ = self.selection.orderedRemove(selected_index);
        }
        if (self.options.presentation != .session_popover and self.options.presentation != .session_tray) {
            var preferred: f32 = 106;
            for (self.visible.items) |index| preferred = @max(preferred, self.cx.text.measureTextWidth(source.value.rows[index].owner_label, 11, 400, false) + 2);
            // Filename gets its measured list-wide width first; only the owner
            // gives up space, retaining a small ellipsis slot on narrow views.
            var filename_width: f32 = 120;
            for (self.visible.items) |index| filename_width = @max(filename_width, self.cx.text.measureTextWidth(source.value.rows[index].name, 12, 400, false) + 2);
            const available = if (self.metadata_layout_width > 0) self.metadata_layout_width else 812;
            const reserved: f32 = 20 + 14 + 76 + 112 + 102 + 30 + (if (self.batch_visible) @as(f32, 22) else 0);
            const budget = @max(0, available - reserved);
            const filename_reserved = @min(filename_width, @max(0, budget - 48));
            self.owner_column_width = @min(preferred, @max(0, budget - filename_reserved));
        }
        if (self.expanded) |target| if (self.task(target) == null) {
            self.expanded = null;
            self.events_open = false;
        };

        const scope_label = if (self.scope_choice) |i| source.value.choices[i].label else source.value.scope_label;
        if (self.selected_scope == .session) {
            try self.format(self.title_badge, "会话 #{d}", .{@backingInt(self.selected_scope.session.session_id)});
        } else try self.title_badge.setTextContent(self.cx.allocator, if (self.selected_scope == .all) "全局" else scope_label);
        try self.notice.setTextContent(self.cx.allocator, source.value.notice);
        self.notice.parent.?.setDisplay(if (self.options.presentation != .session_popover and source.value.notice.len != 0) .flex else .none);
        const values = [_]usize{ self.counts.active, self.counts.waiting, self.counts.paused, self.counts.failed, self.counts.ended };
        for ([_][]const u8{ "进行中", "等待", "暂停", "失败", "结束" }, values, self.counts_labels, 0..) |name, count, node, i| {
            try self.format(node, "{s} {d}", .{ name, count });
            node.setTextColor(if (count == 0) S.theme.current().fg_3 else countColor(i));
            node.parent.?.setStyleInline(self.cx.allocator, S.badge(if (i == 0) 84 else 74, if (count == 0) S.theme.current().fg_3 else countColor(i)));
        }
        const has_tasks = self.counts.active + self.counts.waiting + self.counts.paused + self.counts.failed + self.counts.ended != 0;
        self.counts_row.setDisplay(if (self.options.presentation != .session_tray and has_tasks) .flex else .none);
        self.footer_rate.setDisplay(if (has_tasks) .flex else .none);
        try self.footer_label.setTextContent(self.cx.allocator, scope_label);
        self.footer_label.setDisplay(if (self.options.presentation != .session_tray) .flex else .none);
        try self.format(self.footer_rate, "{d} 进行中 · {d:.1} MiB/s · {d} 等待", .{ self.counts.active, @as(f64, @floatFromInt(self.counts.speed_bps)) / 1048576, self.counts.waiting });
        self.search_node.setDisplay(if (self.search_visible) .flex else .none);
        self.filters_node.setDisplay(if (self.filter_visible) .flex else .none);
        self.batch_row.setDisplay(if (self.batch_visible) .flex else .none);
        if (self.options.presentation == .session_tray) {
            self.scope_row.setDisplay(.none);
            self.counts_row.setDisplay(.none);
            self.foot.setDisplay(.none);
            self.search_node.setDisplay(.none);
            self.filters_node.setDisplay(.none);
            self.notice.parent.?.setDisplay(.none);
        }
        if (self.options.presentation == .session_tray) {
            try self.heading_title.setTextContent(self.cx.allocator, if (self.direction_filter) |direction| (if (direction == .upload) "上传传输" else "下载传输") else "当前会话传输");
            self.root.setDisplay(if (self.tray_requested_show and self.visible.items.len > 0) .flex else .none);
        }
        try self.format(self.batch_label, "已选择 {d} 项", .{self.selection.items.len});
        self.empty_container.setDisplay(if (self.visible.items.len == 0) .flex else .none);
        self.list.container.setDisplay(if (self.visible.items.len == 0) .none else .flex);
        try self.empty.setTextContent(self.cx.allocator, if (self.options.presentation == .global_popover) "没有传输任务" else if (self.options.presentation == .session_popover or self.options.presentation == .session_tray) "当前没有传输任务" else if (self.filter != .all or query.len > 0) "没有符合筛选的任务" else switch (self.selected_scope) {
            .all => "暂无传输任务",
            .session => "本会话暂无传输任务",
            .sessions => "所选组暂无传输任务",
        });
        ui.widgets.virtual_list.updateItemCount(self.virtual, self.visible.items.len);
        rows_reset = true;
        ui.widgets.virtual_list.invalidateHeights(self.virtual);
        ui.widgets.virtual_list.refreshRange(self.virtual, 0, self.visible.items.len);
        // Host refreshes run after before_render. Rebind now so this submitted
        // frame cannot paint the cleared pool while waiting for the next tick.
        self.virtual.updateVisibleItems();
        self.root.markLayoutDirty();
        self.cx.requestRedraw();
    }
    fn renderScopes(self: *Panel) !void {
        if (self.scope_scope) |scope| scope.dispose();
        self.scope_scope = null;
        for ([_]*ui.Node{ self.scope_row, self.tools_row }) |parent| {
            while (parent.children.items.len > 0) {
                const child = parent.children.items[parent.children.items.len - 1];
                self.cx.detachChild(parent, child);
                self.cx.destroyDetached(child);
            }
        }
        self.scope_row.setDisplay(if (self.options.presentation == .session_popover or self.options.presentation == .session_tray) .none else .flex);
        const scope = try self.scope.childScope();
        self.scope_scope = scope;
        const source = self.source orelse return;
        const strip = try ui.widgets.ScrollArea(.{ .direction = .horizontal }).mount(scope, self.cx);
        strip.container.setStyleInline(self.cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0, .height = .{ .px = @import("workspace_tab_styles.zig").height } });
        strip.content.setStyleInline(self.cx.allocator, .{ .direction = .row, .gap = 4, .height = .{ .px = @import("workspace_tab_styles.zig").height }, .align_items = .center });
        try self.scope_row.appendChild(self.cx.allocator, strip.container);
        for (source.value.choices, 0..) |choice, i| {
            if (self.options.presentation == .session_popover) continue;
            if (choice.scope == .sessions) continue;
            if (choice.scope != .all) {
                var has_tasks = false;
                for (source.value.rows) |task_| if (belongs(choice.scope, task_.target.owner)) { has_tasks = true; break; };
                if (!has_tasks) continue;
            }
            const state = try scope.createState(Control, .{ .panel = self, .kind = .choice, .choice = i });
            const tabs = @import("workspace_tab_styles.zig");
            const selected = scopeEql(choice.scope, self.selected_scope);
            const width = std.math.clamp(self.cx.text.measureTextWidth(choice.label, 12, 500, false) + 28, 100, 220);
            const button_ = try ui.box(self.cx, tabs.tab(width, selected), .{});
            button_.behavior.interaction.a11y = .{ .role = .tab, .label = choice.label, .selected = selected };
            button_.behavior.interaction.focusable = true;
            _ = ui.clickable(button_, self.cx.on(Control, state, Control.run));
            const title = try ui.text(self.cx, "", tabs.title());
            try title.setTextContent(self.cx.allocator, choice.label);
            title.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .margin = .{ .left = 10, .right = 10 } });
            try button_.appendChild(self.cx.allocator, title);
            if (selected) try button_.appendChild(self.cx.allocator, try ui.box(self.cx, tabs.underline(width), .{}));
            button_.meta.ownership.meta.test_id = "transfer.scope";
            try strip.content.appendChild(self.cx.allocator, button_);
        }
        try self.v3TaskAction(self.tools_row, scope, if (self.batch_visible) "完成" else "管理", "transfer.batch", .{ .panel = self, .kind = .batch }, false);
        _ = try self.button(self.tools_row, scope, "搜索任务", "transfer.search.toggle", "search", .{ .panel = self, .kind = .search }, false, 28);
        _ = try self.button(self.tools_row, scope, "筛选任务状态", "transfer.filter.toggle", "filter", .{ .panel = self, .kind = .filter }, false, 28);
    }
    fn renderItem(node: *ui.Node, index: usize, cx: *ui.Cx, raw: ?*anyopaque) void {
        const self: *Panel = @ptrCast(@alignCast(raw.?));
        ui.view.renderInto(self.scope, cx, node, renderTask, self, .{index}, "transfer task") catch {
            _ = ui.widgets.virtual_list.markPoolNodeRenderIncomplete(node);
        };
    }
    fn renderTask(self: *Panel, index: usize, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        const task_ = self.source.?.value.rows[self.visible.items[index]];

        const root = try ui.box(cx, S.stack(), .{});
        root.setStyleInline(cx.allocator, .{ .gap = 4 });
        var row_style = S.task(self.isSelected(task_.target));
        if (!self.isSelected(task_.target) and task_.phase == .running) row_style.background = S.theme.current().accent.withAlpha(18);
        const row = try ui.box(cx, row_style, .{});
        row.meta.ownership.meta.test_id = "transfer.task";
        try root.appendChild(cx.allocator, row);
        const compact = self.options.presentation == .session_tray and self.tray_layout_width < 480;
        const upper = try ui.box(cx, S.row(24, if (compact) 3 else 6), .{});
        upper.meta.ownership.meta.test_id = "transfer.task.head";
        try row.appendChild(cx.allocator, upper);
        const control = try scope.createState(Control, .{ .panel = self, .target = task_.target });
        const checkbox = try ui.widgets.Checkbox(.{ .checked = self.isSelected(task_.target), .box_size = @as(f32, 16), .label = "", .disabled = task_.target.owner == null, .on_change = cx.on(Control, control, Control.checked) }).mount(scope, cx);
        checkbox.behavior.interaction.a11y.?.label = "选择传输任务";
        checkbox.meta.ownership.meta.test_id = "transfer.task.select";
        try upper.appendChild(cx.allocator, checkbox);
        checkbox.setDisplay(if (self.batch_visible) .flex else .none);
        const color = phaseColor(task_.phase);
        try upper.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get(if (task_.direction == .upload) "arrow-up-right" else "arrow-down-left").?, color, S.icon(14)));
        checkbox.setStyleInline(cx.allocator, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .min_width = 16, .padding = .ZERO, .flex_shrink = 0 });
        _ = try self.taskTextSlot(upper, scope, task_.name, 12, false, false, "transfer.task.name");
        if (self.options.presentation != .session_tray and self.options.presentation != .session_popover) {
            const owner = try self.label(upper, task_.owner_label, 11, 400, true);
            owner.setStyleInline(cx.allocator, S.label(self.owner_column_width));
            owner.meta.ownership.meta.test_id = "transfer.task.owner";
            if (owner.getText()) |old| {
                var text_props = old;
                text_props.text_overflow = .ellipsis;
                text_props.text_align = .end;
                owner.setText(text_props);
            }
        }
        const status = try self.label(upper, phaseLabel(task_.phase), 11, 400, true);
        status.setTextColor(color);
        status.meta.ownership.meta.test_id = "transfer.task.status";
        status.setStyleInline(cx.allocator, S.label(if (compact) 48 else if (self.options.presentation == .session_tray) 66 else 76));
        if (status.getText()) |value| {
            var props = value;
            props.text_overflow = .ellipsis;
            props.text_align = .end;
            status.setText(props);
        }
        var buffer: [96]u8 = undefined;
        const description = if (task_.phase == .running) try std.fmt.bufPrint(&buffer, "{d:.1} MiB/s", .{@as(f64, @floatFromInt(task_.speed_bps)) / 1048576}) else if (task_.status_detail.len > 0) task_.status_detail else switch (task_.phase) {
            .queued => "等待连接",
            .paused => if (task_.can_resume) "等待继续" else "数据已保留",
            else => "",
        };
        const rate = try self.label(upper, description, 11, 400, true);
        rate.meta.ownership.meta.test_id = "transfer.task.rate";
        rate.setStyleInline(cx.allocator, S.label(if (self.options.presentation == .session_tray) 76 else 112));
        if (v3HasError(task_)) rate.meta.ownership.meta.test_id = "transfer.task.error";
        if (compact) rate.setDisplay(.none);
        if (rate.getText()) |old| {
            var text_props = old;
            text_props.text_align = .end;
            text_props.text_overflow = .ellipsis;
            rate.setText(text_props);
        }
        const actions = try ui.box(cx, S.row(24, 2), .{});
        actions.style.width = .{ .px = 102 };
        actions.style.justify = .end;
        actions.meta.ownership.meta.test_id = "transfer.task.actions";
        try upper.appendChild(cx.allocator, actions);
        // Successful uploads have no local reveal action; their single copy
        // action below matches the HTML card and avoids duplicate copy icons.
        if (!(task_.phase == .succeeded and task_.direction == .upload)) {
            if (primaryAction(task_.phase)) |action| {
                _ = try self.button(actions, scope, actionLabel(action, task_.direction), "transfer.task.primary", actionIcon(action, task_.direction), .{ .panel = self, .target = task_.target, .action = action }, !self.actionAvailable(task_.target) or (action == .resume_transfer and !task_.can_resume) or (action == .reveal and !self.canReveal(task_.target)), 24);
            } else {
                const slot = try ui.box(cx, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .align_items = .center, .justify = .center, .flex_shrink = 0 }, .{});
                try slot.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get(if (task_.phase == .queued or task_.phase == .retry_wait) "clock" else if (task_.phase == .verifying or task_.phase == .pausing or task_.phase == .cancelling) "loader-circle" else "minus").?, S.theme.current().fg_3, S.icon(16)));
                try actions.appendChild(cx.allocator, slot);
            }
        }
        _ = try self.button(actions, scope, "复制远程路径", "transfer.task.copy_path", "copy", .{ .panel = self, .target = task_.target, .kind = .copy_path }, false, 24);
        _ = try self.button(actions, scope, "查看任务事件", "transfer.task.events", "list", .{ .panel = self, .target = task_.target, .kind = .events }, false, 24);
        if (allows(task_.phase, .cancel)) _ = try self.button(actions, scope, "取消任务", "transfer.task.cancel", "x", .{ .panel = self, .target = task_.target, .action = .cancel }, !self.actionAvailable(task_.target), 24);
        const lower = try ui.box(cx, S.row(16, 6), .{});
        lower.meta.ownership.meta.test_id = "transfer.task.meta";
        try row.appendChild(cx.allocator, lower);
        const progress = try self.label(lower, "", 11, 400, true);
        var done_buffer: [40]u8 = undefined;
        var total_buffer: [40]u8 = undefined;
        const done_text = try byteLabel(&done_buffer, task_.done_bytes);
        if (task_.total_bytes) |total| {
            const total_text = try byteLabel(&total_buffer, total);
            if (task_.phase == .running and task_.speed_bps > 0 and total > task_.done_bytes) {
                const remaining = total - task_.done_bytes;
                const seconds = remaining / task_.speed_bps + @intFromBool(remaining % task_.speed_bps != 0);
                try self.format(progress, "{s} / {s} · 约 {d}s", .{ done_text, total_text, seconds });
            } else try self.format(progress, "{s} / {s}", .{ done_text, total_text });
        } else try self.format(progress, "{s} / 大小未知", .{done_text});
        progress.setStyleInline(cx.allocator, .{ .width = .{ .px = if (compact) @max(@as(f32, 1), (self.tray_layout_width - 40) * 0.48) else if (self.options.presentation == .session_tray) 160 else 270 }, .min_width = 0, .flex_shrink = 1, .overflow = .hidden, .overflow_hidden = true });
        _ = try self.taskTextSlot(lower, scope, task_.remote_path, 10.5, true, true, "transfer.task.location");
        {
            const track = try ui.box(cx, S.track(), .{});
            track.meta.ownership.meta.test_id = "transfer.task.progress";
            try row.appendChild(cx.allocator, track);
            const fraction: f64 = if (task_.total_bytes) |total| if (total > 0) @min(@as(f64, 1), @as(f64, @floatFromInt(task_.done_bytes)) / @as(f64, @floatFromInt(total))) else 0 else 0;
            try track.appendChild(cx.allocator, try ui.box(cx, S.fill(@floatCast(fraction), color), .{}));
        }
        const tip = try ui.widgets.Tooltip(.{ .text = "", .open_delay_ms = @as(f32, 450), .position = .bottom_end, .offset = 8, .width = @as(f32, 420), .wrap = .word }).mount(scope, cx);
        const hover = try scope.createState(DetailHover, .{ .cx = cx, .close = tip.wrapper.behavior.events.on_leave, .show = tip.wrapper.behavior.events.on_hover });
        tip.wrapper.behavior.events.on_hover = cx.on(DetailHover, hover, DetailHover.triggerEnter);
        tip.wrapper.behavior.events.on_leave = cx.on(DetailHover, hover, DetailHover.leave);
        tip.wrapper.meta.ownership.debug_slots.state_ptrs[0] = hover;
        tip.wrapper.addBeforeRender(DetailHover.tick);
        tip.content.behavior.events.on_hover = cx.on(DetailHover, hover, DetailHover.enter);
        tip.content.behavior.events.on_leave = cx.on(DetailHover, hover, DetailHover.leave);
        // Keep Tooltip's portal, delay and lifetime; replace its empty label
        // visually with the same structured detail groups as the HTML baseline.
        tip.content.children.items[0].setDisplay(.none);
        tip.content.setStyleInline(cx.allocator, S.hoverDetail());
        const detail_ext = try tip.content.style.ensureExtFallible(cx.allocator);
        detail_ext.hit_shape = .{ .rounded_rect = 10 };
        detail_ext.clip_shape = .{ .rounded_rect = 10 };
        tip.content.meta.ownership.meta.test_id = "transfer.task.hover_detail";
        const identity_text = try std.fmt.allocPrint(cx.allocator, "任务 #{d} · {s}", .{ task_.target.job, task_.owner_label });
        defer cx.allocator.free(identity_text);
        const detail_identity = try self.detailLabel(tip.content, identity_text, false, true, "transfer.detail.identity");
        detail_identity.setStyleInline(cx.allocator, S.hoverDetailIdentity());
        const filename_group = try ui.box(cx, S.hoverDetailField(), .{});
        try tip.content.appendChild(cx.allocator, filename_group);
        _ = try self.detailLabel(filename_group, "文件名", false, true, "transfer.detail.label");
        _ = try self.detailLabel(filename_group, task_.name, false, false, "transfer.detail.name");
        try self.detailField(tip.content, "本地路径", task_.local_path, "transfer.detail.local", scope, task_.target, true);
        try self.detailField(tip.content, "远程路径", task_.remote_path, "transfer.detail.remote", scope, task_.target, false);
        if (task_.options.len != 0) {
            const tags = try ui.box(cx, S.row(24, 6), .{});
            tags.meta.ownership.meta.test_id = "transfer.detail.options";
            try tip.content.appendChild(cx.allocator, tags);
            var parts = std.mem.splitSequence(u8, task_.options, " · ");
            while (parts.next()) |part| {
                const enabled = std.mem.endsWith(u8, part, "开");
                const tag = try ui.box(cx, S.optionTag(enabled), .{});
                try tags.appendChild(cx.allocator, tag);
                var tag_text = S.text(10, 400, true);
                tag_text.color = if (enabled) S.theme.current().ok_ink else S.theme.current().fg_2;
                const label_ = try ui.text(cx, "", tag_text);
                try label_.setTextContent(cx.allocator, part);
                try tag.appendChild(cx.allocator, label_);
            }
        }
        tip.content.behavior.interaction.a11y.?.label = "传输任务详情";
        tip.wrapper.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = S.row_height }, .flex_shrink = 0 });
        tip.trigger.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill() });
        root.removeChild(row);
        try tip.trigger.appendChild(cx.allocator, row);
        try root.appendChild(cx.allocator, tip.wrapper);
        return root;
    }
    fn detailLabel(self: *Panel, parent: *ui.Node, value: []const u8, mono: bool, secondary: bool, test_id: []const u8) !*ui.Node {
        var style = S.text(11, 400, secondary);
        style.use_monospace_font = mono;
        style.line_height = 16.0 / 11.0;
        style.wrap = .word;
        const node = try ui.text(self.cx, "", style);
        try node.setTextContent(self.cx.allocator, value);
        node.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        node.meta.ownership.meta.test_id = test_id;
        try parent.appendChild(self.cx.allocator, node);
        return node;
    }

    fn detailField(self: *Panel, parent: *ui.Node, title: []const u8, value: []const u8, test_id: []const u8, scope: *ui.Scope, target: Target, local: bool) !void {
        const group = try ui.box(self.cx, S.hoverDetailField(), .{});
        try parent.appendChild(self.cx.allocator, group);
        const heading = try ui.box(self.cx, S.row(24, 6), .{});
        try group.appendChild(self.cx.allocator, heading);
        _ = try self.detailLabel(heading, title, false, true, "transfer.detail.label");
        if (value.len != 0) _ = try self.button(heading, scope, if (local) "复制本地路径" else "复制远程路径", if (local) "transfer.detail.copy_local" else "transfer.detail.copy_remote", "copy", .{ .panel = self, .target = target, .kind = if (local) .copy_local_path else .copy_path }, false, 24);
        const path = try self.detailLabel(group, if (value.len != 0) value else "未提供", true, false, test_id);
        if (value.len != 0) {
            const control = try scope.createState(Control, .{ .panel = self, .target = target, .kind = if (local) .copy_local_path else .copy_path });
            _ = ui.clickable(path, self.cx.on(Control, control, Control.run));
        }
    }

    /// Owned shrinking text keeps paint and hit bounds inside its row while
    /// exposing the complete task identity in a bounded native tooltip.
    fn taskTextSlot(self: *Panel, parent: *ui.Node, scope: *ui.Scope, value: []const u8, size: f32, mono: bool, right: bool, test_id: []const u8) !*ui.Node {
        _ = scope;
        const height: f32 = if (mono) 16 else 18;
        const slot = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = height }, .flex = 1, .min_width = 0, .overflow = .hidden, .overflow_hidden = true }, .{});
        try parent.appendChild(self.cx.allocator, slot);
        var style = S.text(size, 400, mono);
        style.text_overflow = .ellipsis;
        style.use_monospace_font = mono;
        style.text_align = if (right) .end else .start;
        const node = try ui.text(self.cx, "", style);
        try node.setTextContent(self.cx.allocator, value);
        node.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = height }, .min_width = 0, .overflow = .hidden, .overflow_hidden = true });
        node.meta.ownership.meta.test_id = test_id;
        try slot.appendChild(self.cx.allocator, node);
        return node;
    }
    fn v3TaskAction(self: *Panel, parent: *ui.Node, scope: *ui.Scope, label_: []const u8, test_id: []const u8, control: Control, disabled: bool) !void {
        const state = try scope.createState(Control, control);
        const owned = try scope.createText(label_, .{});
        const button_ = try ui.widgets.Button(.{ .label = owned, .a11y_label = owned, .variant = .ghost, .base_style = S.v3TextAction(), .disabled = disabled, .on_click = self.cx.on(Control, state, Control.run) }).mount(scope, self.cx);
        button_.meta.ownership.meta.test_id = test_id;
        const label_node = firstTextNode(button_) orelse return error.MissingActionLabel;
        label_node.setStyleInline(self.cx.allocator, .{ .height = .{ .px = 18 } });
        if (label_node.getText()) |old| {
            var props = old;
            props.font_size = 11;
            props.font_weight = 400;
            props.line_height = 18.0 / 11.0;
            label_node.setText(props);
        }
        try parent.appendChild(self.cx.allocator, button_);
    }
    fn v3FooterAction(self: *Panel, parent: *ui.Node, scope: *ui.Scope, label_: []const u8, test_id: []const u8, control: Control, disabled: bool, primary: bool) !void {
        const state = try scope.createState(Control, control);
        const owned = try scope.createText(label_, .{});
        const button_ = try ui.widgets.Button(.{ .label = owned, .a11y_label = owned, .variant = if (primary) ui.widgets.button.ButtonVariant.primary else ui.widgets.button.ButtonVariant.secondary, .base_style = S.v3FooterButton(primary), .disabled = disabled, .on_click = self.cx.on(Control, state, Control.run) }).mount(scope, self.cx);
        button_.meta.ownership.meta.test_id = test_id;
        const label_node = firstTextNode(button_) orelse return error.MissingFooterLabel;
        label_node.setStyleInline(self.cx.allocator, .{ .height = .{ .px = 18 } });
        if (label_node.getText()) |old| {
            var props = old;
            props.font_size = 11;
            props.font_weight = 500;
            props.line_height = 18.0 / 11.0;
            props.color = if (primary) ui.Color.WHITE else S.theme.current().fg_1;
            label_node.setText(props);
        }
        try parent.appendChild(self.cx.allocator, button_);
    }
    fn taskMenu(self: *Panel, parent: *ui.Node, scope: *ui.Scope, task_: Task) !void {
        const menu = try ui.widgets.Popover(.{ .position = .bottom_end, .width = @as(f32, 180), .size_policy = .fit_content, .a11y_role = .menu }).mount(scope, self.cx);
        menu.wrapper.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .flex_shrink = 0 });
        menu.trigger.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .fill() });
        menu.content.meta.ownership.meta.test_id = "transfer.task.menu";
        menu.content.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 2, .padding = ui.Padding.all(4), .background = S.theme.current().overlay, .border = .{ .radius = 8 } });
        const trigger = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.ellipsis, .icon_size = @as(f32, 14), .a11y_label = "任务操作", .base_style = S.action(24) }).mount(scope, self.cx);
        trigger.meta.ownership.meta.test_id = "transfer.task.more";
        try menu.trigger.appendChild(self.cx.allocator, trigger);
        try parent.appendChild(self.cx.allocator, menu.wrapper);
        const entries = [_]struct { label: []const u8, id: []const u8, icon: []const u8, kind: @FieldType(Control, "kind"), action: ?TaskAction = null }{
            .{ .label = "复制远程路径", .id = "transfer.task.copy_path", .icon = "copy", .kind = .copy_path },
            .{ .label = "查看任务事件", .id = "transfer.task.events", .icon = "list", .kind = .events },
            .{ .label = "取消任务", .id = "transfer.task.cancel", .icon = "x", .kind = .action, .action = .cancel },
        };
        for (entries) |entry| {
            if (entry.action) |action| if (!allows(task_.phase, action)) continue;
            const state = try menu.scope.createState(Control, .{ .panel = self, .target = task_.target, .kind = entry.kind, .action = entry.action, .menu_open = menu.open });
            const label_ = try menu.scope.createText(entry.label, .{});
            const button_ = try ui.widgets.Button(.{ .label = label_, .variant = .ghost, .icon_asset = ui.icons.get(entry.icon), .icon_size = @as(f32, 14), .a11y_label = label_, .base_style = ui.BoxStyle{ .width = .fill(), .height = .{ .px = 28 }, .justify = .start, .padding = .{ .left = 8, .right = 8 }, .font_size = 11, .text_color = if (entry.action != null) S.theme.current().danger else S.theme.current().fg_2, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 5 }, .shadow = .{} }, .disabled = entry.action != null and !self.actionAvailable(task_.target), .on_click = self.cx.on(Control, state, Control.run) }).mount(menu.scope, self.cx);
            button_.meta.ownership.meta.test_id = entry.id;
            try menu.content.appendChild(self.cx.allocator, button_);
        }
    }
    fn renderDetail(self: *Panel, root: *ui.Node, scope: *ui.Scope, task_: Task) !void {
        const detail_box = try ui.box(self.cx, S.detail(), .{});
        detail_box.meta.ownership.meta.test_id = "transfer.task.detail";
        try root.appendChild(self.cx.allocator, detail_box);
        const title = try self.label(detail_box, "", 10.5, 400, true);
        if (task_.route.len == 0) try self.format(title, "任务 #{d} · {s}", .{ task_.target.job, task_.owner_label }) else try self.format(title, "任务 #{d} · {s} · {s}", .{ task_.target.job, task_.owner_label, task_.route });
        title.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 26 }, .padding = .{ .left = 8, .right = 8, .top = 5 }, .background = S.theme.current().well, .border = .{ .radius = 8 }, .flex_shrink = 0, .overflow = .hidden });
        if (title.getText()) |value| {
            var props = value;
            props.text_overflow = .ellipsis;
            title.setText(props);
        }
        const paths = try ui.box(self.cx, S.row(20, 8), .{});
        try detail_box.appendChild(self.cx.allocator, paths);
        inline for (.{ .{ "本地", "local_path" }, .{ "远程", "remote_path" } }) |field| {
            const value = try std.fmt.allocPrint(self.cx.allocator, "{s}  {s}", .{ field[0], @field(task_, field[1]) });
            defer self.cx.allocator.free(value);
            const owned = try scope.createText(value, .{});
            const tip = try ui.widgets.Tooltip(.{ .text = owned, .open_delay_ms = @as(f32, 450), .width = @as(f32, 480), .wrap = .word }).mount(scope, self.cx);
            tip.wrapper.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 20 }, .flex = 1, .min_width = 0 });
            tip.trigger.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .fill(), .min_width = 0, .overflow = .hidden, .overflow_hidden = true });
            try paths.appendChild(self.cx.allocator, tip.wrapper);
            var path_text_style = S.text(10.5, 400, true);
            path_text_style.text_overflow = .ellipsis;
            path_text_style.use_monospace_font = true;
            const node = try ui.text(self.cx, owned.get(), path_text_style);
            node.meta.ownership.meta.test_id = if (std.mem.eql(u8, field[1], "local_path")) "transfer.task.detail.local" else "transfer.task.detail.remote";
            try tip.trigger.appendChild(self.cx.allocator, node);
            node.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .height = .{ .px = 17 }, .overflow = .hidden });
            if (node.getText()) |old| {
                var props = old;
                props.text_overflow = .ellipsis;
                props.use_monospace_font = true;
                node.setText(props);
            }
        }
        const metadata = try ui.box(self.cx, S.row(18, 8), .{});
        try detail_box.appendChild(self.cx.allocator, metadata);
        const options = try self.label(metadata, task_.options, 10.5, 400, true);
        options.setTextColor(S.theme.current().accent_ink);
        options.setStyleInline(self.cx.allocator, S.flexibleLabel());
        const summary = try self.label(metadata, if (task_.status_detail.len > 0) task_.status_detail else task_.event_summary, 10.5, 400, true);
        summary.setStyleInline(self.cx.allocator, S.flexibleLabel());
        const actions = try ui.box(self.cx, S.row(24, 4), .{});
        try detail_box.appendChild(self.cx.allocator, actions);
        try actions.appendChild(self.cx.allocator, try ui.spacer(self.cx));
        _ = try self.button(actions, scope, "复制远程路径", "transfer.task.copy_path", "copy", .{ .panel = self, .target = task_.target, .kind = .copy_path }, false, 24);
        _ = try self.button(actions, scope, "查看任务事件", "transfer.task.events", "list", .{ .panel = self, .target = task_.target, .kind = .events }, false, 24);
        _ = try self.button(actions, scope, "收起任务详情", "transfer.task.collapse", "chevron-up", .{ .panel = self, .target = task_.target, .kind = .detail }, false, 24);
    }

    fn itemHeight(index: usize, raw: ?*anyopaque) f32 {
        const p: *Panel = @ptrCast(@alignCast(raw.?));
        if (p.source == null or index >= p.visible.items.len) return S.row_pitch;
        return S.row_pitch;
    }
    fn itemLabel(index: usize, buffer: []u8, raw: ?*anyopaque) []const u8 {
        const p: *Panel = @ptrCast(@alignCast(raw.?));
        if (p.source == null or index >= p.visible.items.len) return "";
        const task_ = p.source.?.value.rows[p.visible.items[index]];
        return std.fmt.bufPrint(buffer, "{s} · {s} · {s}", .{ task_.name, task_.owner_label, phaseLabel(task_.phase) }) catch task_.name;
    }
    fn task(self: *const Panel, target: Target) ?Task {
        const source = self.pending_source orelse self.source orelse return null;
        for (source.value.rows) |task_| if (same(task_.target, target)) return task_;
        return null;
    }
    fn canReveal(self: *const Panel, target: Target) bool {
        if (self.options.presentation == .window) return self.actionAvailable(target);
        if (self.manager == null) return (self.task(target) orelse return false).can_reveal and self.actionAvailable(target);
        const callback = self.callbacks.?.can_reveal orelse return false;
        return callback(self.callbacks.?.context, target.job);
    }
    fn actionAvailable(self: *const Panel, target: Target) bool {
        return target.owner != null and (self.manager != null or self.hooks.action != null);
    }
    pub fn perform(self: *Panel, target: Target, action: TaskAction) !void {
        const task_ = self.task(target) orelse return error.StaleTask;
        if (!allows(task_.phase, action)) return error.ActionUnavailable;
        if (action == .resume_transfer and !task_.can_resume) return error.ActionUnavailable;
        if (action == .reveal and self.options.presentation != .window and !self.canReveal(target)) return error.ActionUnavailable;
        if (target.owner == null) return error.UnknownOwner;
        if (self.manager) |manager| {
            const actual = manager.progress(target.job) orelse return error.StaleTask;
            if (actual.attempt != target.attempt) return error.StaleAttempt;
            if (action == .resume_transfer and !manager.canResume(target.job)) return error.ActionUnavailable;
            const session = manager.sessionId(target.job) orelse return error.StaleTask;
            if (self.callbacks.?.owner) |resolve| {
                const current = resolve(self.callbacks.?.context, target.job) orelse return error.StaleOwner;
                if (target.owner == null or !current.eql(target.owner.?)) return error.StaleOwner;
            }

            if (session != if (target.owner) |owner| @backingInt(owner.session_id) else @as(u64, 0)) return error.StaleOwner;
            const action_: Action = switch (action) {
                .pause => .pause,
                .resume_transfer => .resume_transfer,
                .cancel => .cancel,
                .retry => .retry,
                .reveal => .reveal,
                .new_draft => return error.ActionUnavailable,
                .resolve_conflict => .resolve_conflict,
            };
            self.callbacks.?.action(self.callbacks.?.context, target.job, action_);
        } else {
            if (target.owner == null) return error.UnknownOwner;
            const call = self.hooks.action orelse return error.ActionUnavailable;
            try call(self.hooks.context, target, action);
        }
        self.failure.setDisplay(.none);
    }
    fn performBatch(self: *Panel, action: TaskAction) !void {
        const call = self.hooks.batch orelse return error.ActionUnavailable;
        if (self.selection.items.len == 0) return error.EmptySelection;
        const frozen = try self.cx.allocator.dupe(Target, self.selection.items);
        defer self.cx.allocator.free(frozen);
        for (frozen) |target| {
            const task_ = self.task(target) orelse return error.StaleTask;
            if (target.owner == null or !allows(task_.phase, action)) return error.ActionUnavailable;
        }
        try call(self.hooks.context, frozen, action);
    }
    fn isSelected(self: *const Panel, target: Target) bool {
        for (self.selection.items) |target_| if (same(target_, target)) return true;
        return false;
    }
    fn format(self: *Panel, node: *ui.Node, comptime pattern: []const u8, args: anytype) !void {
        const value = try std.fmt.allocPrint(self.cx.allocator, pattern, args);
        defer self.cx.allocator.free(value);
        try node.setTextContent(self.cx.allocator, value);
    }
    fn invalidate(self: *Panel) void {
        self.dirty = true;
        self.root.markLayoutDirty();
        self.cx.requestRedraw();
    }
    fn fail(self: *Panel, err: anyerror) void {
        self.failure.setTextContent(self.cx.allocator, switch (err) {
            error.StaleTask, error.StaleAttempt, error.StaleOwner => "任务已变化，请重新选择原任务",
            error.UnknownOwner => "任务归属未知，暂不可执行操作",
            error.ActionUnavailable => "此任务当前不支持该操作",
            else => @errorName(err),
        }) catch {};
        self.failure.setTextColor(S.theme.current().danger);
        self.failure.setDisplay(.flex);
        self.cx.requestRedraw();
    }
    fn searchChanged(self: *Panel, _: []const u8) void {
        self.invalidate();
    }
    fn filterChanged(self: *Panel, value: ?[]const u8) void {
        self.filter = std.meta.stringToEnum(Filter, value orelse "all") orelse .all;
        self.invalidate();
    }
    pub fn setDirectionFilter(self: *Panel, direction: ?backend.Direction) void {
        self.direction_filter = direction;
        self.dirty = true;
        self.cx.requestRedraw();
    }
    pub fn setFilter(self: *Panel, filter: Filter) void {
        self.filter = filter;
        self.invalidate();
    }
    pub fn show(self: *Panel) void {
        self.tray_requested_show = true;
        self.root.setDisplay(if (self.options.presentation == .session_tray and self.visible.items.len == 0) .none else .flex);
        self.cx.requestRedraw();
    }
    /// Context switches must not return focus to the previous session's trigger.
    pub fn dismiss(self: *Panel) void {
        self.tray_requested_show = false;
        if (self.event_view) |view| view.close();
        self.cx.invalidateReferencesTo(self.root);
        self.root.setDisplay(.none);
        self.cx.requestRedraw();
    }
    pub fn hide(self: *Panel) void {
        self.tray_requested_show = false;
        if (self.event_view) |view| view.close();
        if (self.options.presentation != .window) {
            self.cx.invalidateReferencesTo(self.root);
            if (self.cx.root) |root| if (self.anchor_id) |anchor| if (findNode(root, anchor)) |node| self.cx.setFocus(node);
        }
        self.root.setDisplay(.none);
        self.cx.requestRedraw();
    }
    pub fn setAnchor(self: *Panel, anchor: *ui.Node) void {
        self.anchor_id = anchor.id;
        self.invalidate();
    }
    pub fn setWindowHook(self: *Panel, context: *anyopaque, callback: *const fn (*anyopaque, WindowAction) anyerror!void) void {
        self.window_context = context;
        self.hooks.window = callback;
        self.window_disabled.set(false);
    }
    pub fn retheme(self: *Panel) void {
        if (self.event_view) |view| view.retheme();
        S.repaint(self.root, self.paint_colors);
        self.paint_colors = S.theme.current();
        self.root.setStyleInline(self.cx.allocator, if (self.options.presentation == .session_tray) S.sessionTray() else S.panel(true));
        self.scopes_dirty = true;
        self.invalidate();
    }
    pub fn refresh(self: *Panel, now: u64, stats: Statistics) !void {
        if (self.in_action) {
            self.pending_refresh = .{ .now = now, .stats = stats };
            self.invalidate();
            return;
        }
        const manager = self.manager orelse return;
        var arena = std.heap.ArenaAllocator.init(self.cx.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const rows = try a.alloc(Task, manager.count());
        for (rows, 0..) |*row, i| {
            const p = manager.progressAt(i).?;
            const spec = manager.jobs.items[i].spec;
            const session = manager.sessionId(p.job) orelse 0;
            const original = manager.sourceName(i) orelse "";
            const name = spec.rename orelse std.fs.path.basename(original);
            const display_name = if (spec.sources.len > 1) try std.fmt.allocPrint(a, "{s} 等{d}个文件", .{ name, spec.sources.len }) else name;
            row.* = .{ .target = .{ .job = p.job, .attempt = p.attempt, .owner = if (self.callbacks.?.owner) |resolve| resolve(self.callbacks.?.context, p.job) else if (session == 0) null else .{ .session_id = @fromBackingInt(session) } }, .direction = spec.direction, .name = display_name, .owner_label = if (session == 0) "归属未知" else try std.fmt.allocPrint(a, "会话 #{d}", .{session}), .local_path = if (spec.direction == .upload) original else try std.fs.path.join(a, &.{ spec.local_dir, name }), .remote_path = if (spec.direction == .download) original else try std.fs.path.join(a, &.{ spec.remote_dir, name }), .phase = if (p.job_cleanup == .unknown) .cleanup_unknown else if (p.state == .failed and p.failure == .checksum) .checksum_failed else std.meta.stringToEnum(Phase, @tagName(p.state)).?, .done_bytes = p.done_bytes, .total_bytes = if (p.total_bytes == 0 and p.state != .succeeded) null else p.total_bytes, .speed_bps = p.speed_bps, .status_detail = if (p.failure) |failure| failureLabel(failure) else "", .route = if (self.callbacks.?.metadata) |call| call(self.callbacks.?.context, p.job) else "", .options = try std.fmt.allocPrint(a, "断点续传 {s} · MD5 {s}", .{ if (spec.resume_transfer) "开" else "关", if (spec.md5_check) "开" else "关" }) };
            if (p.state == .running) if (p.verification) |verification| {
                row.phase = .verifying;
                row.speed_bps = 0;
                row.status_detail = switch (verification.state) {
                    .repairing => "正在修复末块",
                    .unavailable => "校验不可用",
                    else => "正在校验",
                };
            };
            if (p.state == .running and p.conflict_waiting) {
                row.phase = .conflict;
                row.speed_bps = 0;
                row.status_detail = "";
            }
            if (p.state == .succeeded and p.skipped_files > 0) {
                if (p.skipped_files == spec.sources.len) row.phase = .skipped;
                row.status_detail = try std.fmt.allocPrint(a, "已跳过 {d} 项", .{p.skipped_files});
            }
            if (self.callbacks.?.owner_label) |read_label| row.owner_label = try std.fmt.allocPrint(a, "{s} #{d}", .{ read_label(self.callbacks.?.context, p.job), session });
            row.events = try eventText(a, manager, p);
            const history = manager.eventHistory(p.job) orelse &.{};
            row.event_summary = try std.fmt.allocPrint(a, "{d} 条状态事件 · 当前尝试 {d} · {s}", .{ history.len, p.attempt, phaseLabel(row.phase) });
            row.can_resume = manager.canResume(p.job);
            row.can_reveal = if (self.callbacks.?.can_reveal) |read_capability| read_capability(self.callbacks.?.context, p.job) else false;
        }
        var speed: u64 = 0;
        for (rows) |row| if (row.phase == .running) {
            speed +|= row.speed_bps;
        };
        if (self.last_sample_ms == null or now >= self.last_sample_ms.? + 500) {
            std.mem.copyForwards(u64, self.samples[0..7], self.samples[1..8]);
            self.samples[7] = speed;
            self.sample_count = @min(8, self.sample_count + 1);
            self.last_sample_ms = now;
        }
        var choices: std.ArrayList(ScopeChoice) = .empty;
        try choices.append(a, .{ .label = "全部会话", .scope = .all });
        if (self.callbacks.?.scope_choices) |extra| try choices.appendSlice(a, try extra(self.callbacks.?.context, a));
        for (rows) |row| if (row.target.owner) |owner| {
            var exists = false;
            for (choices.items) |choice| if (scopeEql(choice.scope, .{ .session = owner })) {
                exists = true;
                break;
            };
            if (!exists) try choices.append(a, .{ .label = row.owner_label, .scope = .{ .session = owner } });
        };
        var selected: Scope = if (self.options.presentation == .session_popover or self.options.presentation == .session_tray) self.selected_scope else .all;
        var scope_label: []const u8 = if (self.options.presentation == .session_popover or self.options.presentation == .session_tray) (if (self.selected_scope == .sessions) "当前组" else "当前会话") else "全部会话";
        for (choices.items) |choice| if (scopeEql(choice.scope, self.selected_scope)) {
            selected = choice.scope;
            scope_label = choice.label;
            break;
        };
        try self.update(.{ .revision = self.revision + 1, .rows = rows, .choices = choices.items, .scope = selected, .scope_label = scope_label });
    }
    /// True only for a mounted task row intersecting this list's viewport.
    /// Consult current manager state too: a completion can precede snapshot paint.
    pub fn presents(self: *const Panel, job: backend.JobId) bool {
        const source = self.source orelse return false;
        const clip = self.list.container.globalRect();
        if (clip.w <= 0 or clip.h <= 0) return false;
        for (self.virtual.pool_bindings, 0..) |binding, slot| {
            const visible_index = binding orelse continue;
            if (visible_index >= self.visible.items.len) continue;
            const task_ = source.value.rows[self.visible.items[visible_index]];
            if (task_.target.job != job or !belongs(self.selected_scope, task_.target.owner)) continue;
            if (self.direction_filter) |direction| if (task_.direction != direction) continue;
            var phase = task_.phase;
            if (self.manager) |manager| if (manager.progress(job)) |progress| {
                phase = if (progress.job_cleanup == .unknown) .cleanup_unknown else if (progress.state == .failed and progress.failure == .checksum) .checksum_failed else std.meta.stringToEnum(Phase, @tagName(progress.state)).?;
            };
            if (self.filter != .all and self.filter != category(phase)) continue;
            const search_text = self.search.peek();
            if (search_text.len > 0 and !contains(task_.name, search_text) and !contains(task_.local_path, search_text) and !contains(task_.remote_path, search_text) and !contains(task_.owner_label, search_text)) continue;
            const rect = self.virtual.pool_nodes[slot].globalRect();
            if (rect.w > 0 and rect.h > 0 and rect.x < clip.x + clip.w and rect.x + rect.w > clip.x and rect.y < clip.y + clip.h and rect.y + rect.h > clip.y) return true;
        }
        return false;
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const p: *Panel = @ptrCast(@alignCast(raw));
        if (p.pending_refresh) |pending| {
            p.pending_refresh = null;
            p.refresh(pending.now, pending.stats) catch {};
            return .needs_layout;
        }
        if (p.dirty) {
            p.flush() catch {};
            return .needs_layout;
        }
        if (p.root.style.display == .none) return .done;
        const parent = p.root.parent orelse return .done;
        const bounds = parent.globalRect();
        if (bounds.w <= 0 or bounds.h <= 0) return .done;
        if (p.options.presentation != .session_popover and p.options.presentation != .session_tray) {
            const width = p.list.container.globalRect().w - p.list.content.style.padding.right;
            if (width > 0 and @abs(width - p.metadata_layout_width) > 0.5) {
                p.metadata_layout_width = width;
                p.dirty = true;
                return .needs_layout;
            }
        }
        if (p.options.presentation == .window) {
            const available_width = @max(0, bounds.w - parent.style.padding.left - parent.style.padding.right);
            const available_height = @max(0, bounds.h - parent.style.padding.top - parent.style.padding.bottom);
            const width = if (p.options.fill_window) available_width else @min(@as(f32, 840), available_width);
            const height = if (p.options.fill_window) available_height else @min(@as(f32, 578), available_height);
            if (p.root.style.width == .px and p.root.style.height == .px and p.root.style.width.px == width and p.root.style.height.px == height) return .done;
            p.root.setStyleInline(p.cx.allocator, .{ .width = .{ .px = width }, .height = .{ .px = height } });
            return .needs_layout;
        }
        if (p.options.presentation == .session_tray) {
            // Width changes must rebind virtual rows, including the first real
            // layout after mount (where no usable width was available yet).
            const actual_width = p.root.globalRect().w;
            if (actual_width > 0 and @abs(actual_width - p.tray_layout_width) > 0.5) {
                p.tray_layout_width = actual_width;
                p.dirty = true;
                p.cx.requestRedraw();
                return .needs_layout;
            }
            var task_height: f32 = 0;
            for (p.visible.items, 0..) |_, i| task_height += itemHeight(i, p);
            // Keep file rows usable at the minimum window height; extra
            // transfer rows stay in this list's native scroll viewport.
            // Header/insets and list gap preserve one complete compact row.
            // 9/8px insets + 28px header + 6px gap + one complete card.
            // A short/self-sized parent must not feed the old clipped height
            // back into this budget; management adds its own 28px row.
            const chrome: f32 = 9 + 28 + 6 + 8 + (if (p.batch_visible) @as(f32, 28) else 0);
            const minimum: f32 = chrome + S.row_height;
            const maximum = @min(@as(f32, 190), @max(minimum, bounds.h * 0.32));
            const height = std.math.clamp(chrome + task_height, minimum, maximum);
            if (p.root.style.height == .px and p.root.style.height.px == height) return .done;
            p.root.setStyleInline(p.cx.allocator, .{ .width = .fill(), .height = .{ .px = height }, .padding = .{ .top = 9, .right = 12, .bottom = 8, .left = 12 } });
            return .needs_layout;
        }
        const global = p.options.presentation == .global_popover;
        const desired_width: f32 = 760;
        const width = @max(@as(f32, 1), @min(desired_width, bounds.w - 24));
        var list_height: f32 = 0;
        for (p.visible.items, 0..) |_, i| list_height += itemHeight(i, p);
        if (list_height == 0) list_height = 100;
        const max_height = @max(@as(f32, 1), @min(bounds.h - 24, @as(f32, 578)));
        const failure_height: f32 = if (p.failure.style.display != .none) @max(@as(f32, 24), p.failure.globalRect().h) else 0;
        const notice_height: f32 = if (p.notice.parent.?.style.display != .none) @max(@as(f32, 36), p.notice.parent.?.globalRect().h) else 0;
        const chrome: f32 = (if (global) @as(f32, 188) else 144) + (if (p.batch_visible) @as(f32, 28) else 0);
        const presentation_cap: f32 = if (global) 578 else 420;
        const height = @min(chrome + list_height + failure_height + notice_height, @min(presentation_cap, max_height));
        var top: f32 = 46;
        var right: f32 = 12;
        if (p.anchor_id) |id| {
            if (findNode(p.cx.root orelse return .done, id)) |anchor| {
                const r = anchor.globalRect();
                const left = std.math.clamp(r.x - bounds.x, @as(f32, 12), @max(@as(f32, 12), bounds.w - width - 12));
                right = bounds.w - width - left;
                top = if (global) r.y - bounds.y + r.h + 8 else r.y - bounds.y - height - 8;
                if (global and top + height > bounds.h - 12) top = r.y - bounds.y - height - 8;
            } else {
                p.hide();
                return .done;
            }
        }
        // UI_V3 placeOverlay: 12px window bounds, 8px anchor gap, flip before clamping.
        top = std.math.clamp(top, @as(f32, 12), @max(@as(f32, 12), bounds.h - height - 12));
        right = std.math.clamp(right, @as(f32, 12), @max(@as(f32, 12), bounds.w - width - 12));
        const ext = p.root.style.ensureExtPanic(p.cx.allocator);
        if (p.root.style.width.px == width and p.root.style.height.px == height and ext.inset.top.px == top and ext.inset.right.px == right) return .done;
        p.root.setStyleInline(p.cx.allocator, .{ .width = .{ .px = width }, .height = .{ .px = height }, .inset = .{ .top = .{ .px = top }, .right = .{ .px = right } } });
        return .needs_layout;
    }
};
fn firstTextNode(node: *ui.Node) ?*ui.Node {
    if (node.getText() != null) return node;
    for (node.children.items) |child| if (firstTextNode(child)) |found| return found;
    return null;
}
fn v3RateLabel(task_: Task, buffer: *[96]u8, total_buffer: *[40]u8) []const u8 {
    if (task_.status_detail.len > 0 and !v3HasError(task_)) return task_.status_detail;
    if (task_.phase == .paused) return if (task_.can_resume) "等待继续" else "数据已保留";
    const fraction: f64 = if (task_.total_bytes) |total| if (total > 0) @min(@as(f64, 1), @as(f64, @floatFromInt(task_.done_bytes)) / @as(f64, @floatFromInt(total))) else 0 else 0;
    if (task_.phase == .running) return std.fmt.bufPrint(buffer, "{d:.0}% · {d:.1} MiB/s", .{ fraction * 100, @as(f64, @floatFromInt(task_.speed_bps)) / 1048576 }) catch "大小待确认";
    const total = if (task_.total_bytes) |bytes| byteLabel(total_buffer, bytes) catch "大小待确认" else "大小待确认";
    return std.fmt.bufPrint(buffer, "{d:.0}% · {s}", .{ fraction * 100, total }) catch "大小待确认";
}
fn v3HasError(task_: Task) bool {
    return (task_.phase == .failed or task_.phase == .checksum_failed) and task_.status_detail.len > 0;
}
fn v3TaskHeight(task_: Task) f32 {
    _ = task_;
    return S.v3_card_height;
}
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, needle) != null;
}
fn findNode(node: *ui.Node, id: u32) ?*ui.Node {
    if (node.id == id) return node;
    for (node.children.items) |child| if (findNode(child, id)) |found| return found;
    return null;
}
fn countColor(index: usize) ui.Color {
    const c = S.theme.current();
    return switch (index) {
        0 => c.accent_ink,
        2 => c.warn_ink,
        3 => c.danger_ink,
        4 => c.ok_ink,
        else => c.fg_2,
    };
}
fn phaseColor(phase: Phase) ui.Color {
    return countColor(switch (category(phase)) {
        .active => 0,
        .paused => 2,
        .failed => 3,
        .ended => if (phase == .succeeded or phase == .skipped) @as(usize, 4) else @as(usize, 1),
        else => 1,
    });
}
fn primaryAction(phase: Phase) ?TaskAction {
    return switch (phase) {
        .running => .pause,
        .conflict => .resolve_conflict,
        .paused => .resume_transfer,
        .failed => .retry,
        .succeeded => .reveal,
        .cancelled, .checksum_failed => .new_draft,
        else => null,
    };
}
fn actionIcon(action: TaskAction, direction: backend.Direction) []const u8 {
    return switch (action) {
        .pause => "pause",
        .resolve_conflict => "triangle-alert",
        .resume_transfer => "play",
        .retry => "rotate-cw",
        .reveal => if (direction == .upload) "copy" else "folder-open",
        .new_draft => "file-plus",
        .cancel => "x",
    };
}
fn actionLabel(action: TaskAction, direction: backend.Direction) []const u8 {
    return switch (action) {
        .pause => "暂停传输",
        .resolve_conflict => "处理同名文件",
        .resume_transfer => "继续传输",
        .retry => "重试原任务",
        .reveal => if (direction == .upload) "复制远程路径" else "打开本地目录",
        .new_draft => "再次传输，重新核对",
        .cancel => "取消传输",
    };
}

fn eventText(a: std.mem.Allocator, manager: *const backend.Manager, progress: backend.Progress) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try output.writer.print("任务 #{d} · 会话 #{d}\n", .{ progress.job, manager.sessionId(progress.job) orelse 0 });
    const history = manager.eventHistory(progress.job) orelse &.{};
    if (history.len > 0 and history[0].sequence > 1) try output.writer.writeAll("仅保留最近 32 条状态事件\n");
    for (history) |event| {
        if (event.timestamp_ms) |stamp| {
            const seconds = (stamp / 1000) % 86400;
            try output.writer.print("{d:0>2}:{d:0>2}:{d:0>2} UTC  ", .{ seconds / 3600, (seconds / 60) % 60, seconds % 60 });
        }
        const state = if (event.attempt == 0 and event.state == .queued) "入队" else phaseLabel(std.meta.stringToEnum(Phase, @tagName(event.state)).?);
        try output.writer.print("{s} · 尝试 {d}", .{ state, event.attempt });
        if (event.binding_wait) try output.writer.writeAll(" · 等待连接");
        if (event.conflict_waiting) try output.writer.writeAll(" · 等待处理同名冲突");
        if (event.failure) |failure| try output.writer.print(" · {s}", .{failureLabel(failure)});
        if (event.verification) |verification| try output.writer.print(" · {s}", .{switch (verification) {
            .pending => "等待校验",
            .reading => "正在校验",
            .repairing => "正在修复末块",
            .passed => "校验通过",
            .failed => "校验失败",
            .unavailable => "校验不可用",
        }});
        if (event.attempt > 0 and event.state != .running) try output.writer.print(" · {s}", .{switch (event.cleanup) {
            .awaiting => "等待资源释放",
            .released => "资源已释放",
            .unknown => "资源释放待核实",
        }});
        try output.writer.writeAll("\n");
    }
    if (progress.total_bytes == 0 and progress.state != .succeeded) try output.writer.print("当前进度 · 已传 {d} B · 大小未知", .{progress.done_bytes}) else try output.writer.print("当前进度 · 已传 {d} / {d} B", .{ progress.done_bytes, progress.total_bytes });
    return output.toOwnedSlice();
}

fn byteLabel(buffer: []u8, bytes: u64) ![]const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes});
    if (bytes < 1048576) return std.fmt.bufPrint(buffer, "{d:.1} KiB", .{@as(f64, @floatFromInt(bytes)) / 1024});
    return std.fmt.bufPrint(buffer, "{d:.1} MiB", .{@as(f64, @floatFromInt(bytes)) / 1048576});
}
