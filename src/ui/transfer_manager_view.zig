//! Vanta transfer views. The application owns IO and native windows. Closing
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
    scope_choices: ?*const fn (*anyopaque, std.mem.Allocator) anyerror![]const ScopeChoice = null,
    owner_label: ?*const fn (*anyopaque, backend.JobId) []const u8 = null,
    metadata: ?*const fn (*anyopaque, backend.JobId) []const u8 = null,
    owner: ?*const fn (*anyopaque, backend.JobId) ?identity.SessionHandle = null,
};
pub const Statistics = struct { window_chunks: u8, chunk_kb: u16, today_bytes: ?u64 = null };
pub const Presentation = enum { window, global_popover, session_popover };
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
        a.can_resume != b.can_resume) return false;
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
    const panel = try mountProjection(cx, scope, .{ .presentation = .session_popover }, .{ .context = callbacks.context });
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

const Control = struct {
    panel: *Panel,
    target: ?Target = null,
    action: ?TaskAction = null,
    window: ?WindowAction = null,
    choice: ?usize = null,
    kind: enum { action, detail, events, copy_path, window, choice, search, filter, new_transfer, batch, batch_pause, batch_resume, batch_cancel, all_tasks, scope_tasks } = .action,
    fn run(self: *Control) void {
        const p = self.panel;
        p.in_action = true;
        defer p.in_action = false;
        switch (self.kind) {
            .action => p.perform(self.target.?, self.action.?) catch |err| p.fail(err),
            .events => {
                const task_ = p.task(self.target.?) orelse return;
                if (p.event_view == null) p.event_view = @import("transfer_events_view.zig").View.mount(p.cx, p.scope) catch |err| {
                    p.fail(err);
                    return;
                };
                p.event_view.?.show(task_.target.job, task_.events) catch |err| p.fail(err);
            },
            .copy_path => {
                const task_ = p.task(self.target.?) orelse return;
                if (!ui.platform_services.clipboardSetText(p.cx.system_sdk, task_.remote_path)) p.fail(error.ClipboardUnavailable);
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
                p.batch_visible = !p.batch_visible;
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
        p.batch_visible = p.selection.items.len > 0;
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
    counts: Counts = .{},
    expanded: ?Target = null,
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
    counts_row: *ui.Node,
    counts_labels: [5]*ui.Node,
    title_badge: *ui.Node,
    notice: *ui.Node,
    footer_label: *ui.Node,
    footer_rate: *ui.Node,
    empty: *ui.Node,
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
        p.* = .{ .cx = cx, .scope = scope, .root = undefined, .options = options, .hooks = hooks, .window_disabled = try scope.createSignal(bool, hooks.window == null), .paint_colors = S.theme.current(), .head = undefined, .heading_title = undefined, .foot = undefined, .scope_row = undefined, .counts_row = undefined, .counts_labels = undefined, .title_badge = undefined, .notice = undefined, .footer_label = undefined, .footer_rate = undefined, .empty = undefined, .failure = undefined, .search = try scope.createText("", .{}), .search_node = undefined, .filters_node = undefined, .batch_row = undefined, .batch_label = undefined, .list = undefined, .virtual = undefined };
        try scope.onCleanup(Panel, p, cleanup);
        const window = options.presentation != .session_popover;
        const native_window = options.presentation == .window;
        p.root = try ui.box(cx, S.panel(window), .{});
        p.root.meta.ownership.meta.test_id = "transfer.manager";
        if (!native_window) p.root.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .top = .{ .px = 46 }, .right = .{ .px = 14 } }, .z_index = 50 });
        p.root.setDisplay(.none);
        p.head = try ui.box(cx, S.row(30, 6), .{});
        try p.root.appendChild(cx.allocator, p.head);
        try p.root.insertChildBefore(cx.allocator, try ui.boxStyled(cx, S.topFade, .{}), p.head);
        try p.root.appendChild(cx.allocator, try ui.boxStyled(cx, S.grip, .{}));
        try p.head.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("arrow-down-up").?, S.theme.current().accent, S.icon(18)));
        const heading_title = try p.label(p.head, if (window) "传输任务" else "本会话传输", 13, 700, false);
        p.heading_title = heading_title;
        heading_title.setStyleInline(cx.allocator, S.label(72));
        if (!window) try p.head.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("lock-keyhole").?, S.theme.current().fg_2, S.icon(12)));
        p.title_badge = try p.label(p.head, "", 10.5, 400, true);
        p.title_badge.setDisplay(if (window) .none else .flex);
        p.title_badge.setStyleInline(cx.allocator, .{ .height = .{ .px = 22 }, .padding = .{ .left = 8, .right = 8 }, .background = S.theme.current().surface_2, .border = .{ .radius = 6 } });
        try p.head.appendChild(cx.allocator, try ui.spacer(cx));
        if (native_window) {
            _ = try p.button(p.head, scope, "最小化传输窗口", "transfer.window.minimize", "minus", .{ .panel = p, .kind = .window, .window = .minimize }, p.window_disabled, 22);
            _ = try p.button(p.head, scope, "缩放传输窗口", "transfer.window.zoom", "maximize-2", .{ .panel = p, .kind = .window, .window = .zoom }, p.window_disabled, 22);
        }
        _ = try p.button(p.head, scope, "收起传输", "transfer.window.close", "x", .{ .panel = p, .kind = .window, .window = .close }, false, 22);
        try p.root.appendChild(cx.allocator, try ui.box(cx, S.gap(9), .{}));
        p.scope_row = try ui.box(cx, S.row(32, 6), .{});
        try p.root.appendChild(cx.allocator, p.scope_row);
        p.counts_row = try ui.box(cx, S.row(28, 6), .{});
        try p.root.appendChild(cx.allocator, p.counts_row);
        for (&p.counts_labels, 0..) |*label_, i| {
            const box = try ui.box(cx, S.badge(if (i == 0) 84 else 74, countColor(i)), .{});
            label_.* = try p.label(box, "", 10, 500, true);
            try p.counts_row.appendChild(cx.allocator, box);
        }
        try p.counts_row.appendChild(cx.allocator, try ui.spacer(cx));
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
        empty_state.meta.ownership.meta.test_id = "transfer.empty";
        try p.root.appendChild(cx.allocator, empty_state);
        try empty_state.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.folder_open, S.theme.current().fg_2, S.icon(18)));
        p.empty = try p.label(empty_state, "", 12, 500, false);
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
        p.list.content.style.padding.right = 14;
        try p.root.appendChild(cx.allocator, list.container);
        try p.root.appendChild(cx.allocator, try ui.box(cx, S.gap(if (window) 6 else 12), .{}));
        p.foot = try ui.box(cx, S.row(if (window) 32 else 30, 6), .{});
        try p.root.appendChild(cx.allocator, p.foot);
        p.footer_label = try p.label(p.foot, "", 10.5, 400, true);
        p.footer_label.setStyleInline(cx.allocator, .{ .width = .{ .px = 210 }, .min_width = 0, .overflow = .hidden, .flex_shrink = 1 });
        p.footer_rate = try p.label(p.foot, "", 10.5, 400, true);
        p.footer_rate.setStyleInline(cx.allocator, S.flexibleLabel());
        if (window) {
            _ = try p.button(p.foot, scope, "查看全部任务", "transfer.open.all", "list", .{ .panel = p, .kind = .all_tasks }, false, 28);
            _ = try p.button(p.foot, scope, "所选任务操作", "transfer.batch", "ellipsis", .{ .panel = p, .kind = .batch }, false, 28);
        } else {
            _ = try p.button(p.foot, scope, "查看全部任务", "transfer.open.all", "list", .{ .panel = p, .kind = .all_tasks }, hooks.open_manager == null, 28);
            _ = try p.button(p.foot, scope, "查看会话任务", "transfer.open.scope", "list", .{ .panel = p, .kind = .scope_tasks }, hooks.open_manager == null, 28);
        }
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
        const node = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.get(icon), .icon_size = 16, .a11y_label = owned_label, .base_style = S.action(size), .disabled = disabled, .on_click = self.cx.on(Control, state, Control.run) }).mount(scope, self.cx);
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
        if (self.expanded) |target| if (self.task(target) == null) {
            self.expanded = null;
            self.events_open = false;
        };
        if (self.options.presentation == .session_popover) try self.heading_title.setTextContent(self.cx.allocator, if (self.selected_scope == .sessions) "本组传输" else "本会话传输");
        const scope_label = if (self.scope_choice) |i| source.value.choices[i].label else source.value.scope_label;
        if (self.selected_scope == .session) {
            try self.format(self.title_badge, "会话 #{d}", .{@backingInt(self.selected_scope.session.session_id)});
        } else try self.title_badge.setTextContent(self.cx.allocator, scope_label);
        try self.notice.setTextContent(self.cx.allocator, source.value.notice);
        self.notice.parent.?.setDisplay(if (self.options.presentation != .session_popover and source.value.notice.len != 0) .flex else .none);
        const values = [_]usize{ self.counts.active, self.counts.waiting, self.counts.paused, self.counts.failed, self.counts.ended };
        for ([_][]const u8{ "进行中", "等待", "暂停", "失败", "结束" }, values, self.counts_labels, 0..) |name, count, node, i| {
            try self.format(node, "{s} {d}", .{ name, count });
            node.setTextColor(if (count == 0) S.theme.current().fg_3 else countColor(i));
            node.parent.?.setStyleInline(self.cx.allocator, S.badge(if (i == 0) 84 else 74, if (count == 0) S.theme.current().fg_3 else countColor(i)));
        }
        const has_tasks = self.counts.active + self.counts.waiting + self.counts.paused + self.counts.failed + self.counts.ended != 0;
        self.counts_row.setDisplay(if (self.options.presentation != .session_popover and has_tasks) .flex else .none);
        self.footer_rate.setDisplay(if (has_tasks) .flex else .none);
        try self.footer_label.setTextContent(self.cx.allocator, if (self.options.presentation == .session_popover) scope_label else "");
        self.footer_label.setDisplay(if (self.options.presentation == .session_popover) .flex else .none);
        try self.format(self.footer_rate, "{d} 进行中 · {d:.1} MiB/s · {d} 等待", .{ self.counts.active, @as(f64, @floatFromInt(self.counts.speed_bps)) / 1048576, self.counts.waiting });
        self.search_node.setDisplay(if (self.search_visible) .flex else .none);
        self.filters_node.setDisplay(if (self.filter_visible) .flex else .none);
        self.batch_row.setDisplay(if (self.batch_visible) .flex else .none);
        try self.format(self.batch_label, "已选择 {d} 项", .{self.selection.items.len});
        self.empty.parent.?.setDisplay(if (self.visible.items.len == 0) .flex else .none);
        self.list.container.setDisplay(if (self.visible.items.len == 0) .none else .flex);
        try self.empty.setTextContent(self.cx.allocator, if (self.filter != .all or query.len > 0) "没有符合筛选的任务" else switch (self.selected_scope) {
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
        while (self.scope_row.children.items.len > 0) {
            const child = self.scope_row.children.items[self.scope_row.children.items.len - 1];
            self.cx.detachChild(self.scope_row, child);
            self.cx.destroyDetached(child);
        }
        const scope = try self.scope.childScope();
        self.scope_scope = scope;
        const source = self.source orelse return;
        const strip = try ui.widgets.ScrollArea(.{ .direction = .horizontal }).mount(scope, self.cx);
        strip.container.setStyleInline(self.cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0, .height = .{ .px = 32 } });
        strip.content.setStyleInline(self.cx.allocator, .{ .direction = .row, .gap = 6, .height = .{ .px = 32 }, .align_items = .center });
        try self.scope_row.appendChild(self.cx.allocator, strip.container);
        for (source.value.choices, 0..) |choice, i| {
            const state = try scope.createState(Control, .{ .panel = self, .kind = .choice, .choice = i });
            const label_ = try scope.createText(choice.label, .{});
            const selected = scopeEql(choice.scope, self.selected_scope);
            const button_ = try ui.widgets.Button(.{ .label = label_, .variant = if (selected) ui.widgets.button.ButtonVariant.primary else ui.widgets.button.ButtonVariant.secondary, .a11y_label = label_, .base_style = S.choice(if (i == 0) 100 else if (i == 1) 146 else 132, selected), .on_click = self.cx.on(Control, state, Control.run) }).mount(scope, self.cx);
            button_.meta.ownership.meta.test_id = "transfer.scope";
            try strip.content.appendChild(self.cx.allocator, button_);
        }
        _ = try self.button(self.scope_row, scope, "搜索任务", "transfer.search.toggle", "search", .{ .panel = self, .kind = .search }, false, 28);
        _ = try self.button(self.scope_row, scope, "筛选任务状态", "transfer.filter.toggle", "filter", .{ .panel = self, .kind = .filter }, false, 28);
    }
    fn renderItem(node: *ui.Node, index: usize, cx: *ui.Cx, raw: ?*anyopaque) void {
        const self: *Panel = @ptrCast(@alignCast(raw.?));
        ui.view.renderInto(self.scope, cx, node, renderTask, self, .{index}, "transfer task") catch {
            _ = ui.widgets.virtual_list.markPoolNodeRenderIncomplete(node);
        };
    }
    fn renderTask(self: *Panel, index: usize, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        const task_ = self.source.?.value.rows[self.visible.items[index]];
        const expanded = self.expanded != null and same(self.expanded.?, task_.target);
        const root = try ui.box(cx, S.stack(), .{});
        root.setStyleInline(cx.allocator, .{ .gap = 4 });
        const row = try ui.box(cx, S.task(self.isSelected(task_.target)), .{});
        row.meta.ownership.meta.test_id = "transfer.task";
        try root.appendChild(cx.allocator, row);
        const upper = try ui.box(cx, S.row(24, 6), .{});
        try row.appendChild(cx.allocator, upper);
        const control = try scope.createState(Control, .{ .panel = self, .target = task_.target });
        const checkbox = try ui.widgets.Checkbox(.{ .checked = self.isSelected(task_.target), .box_size = @as(f32, 16), .label = "", .disabled = task_.target.owner == null, .on_change = cx.on(Control, control, Control.checked) }).mount(scope, cx);
        if (checkbox.children.items.len > 0) checkbox.children.items[0].setStyleInline(cx.allocator, .{ .background = if (self.isSelected(task_.target)) S.theme.current().accent else S.theme.current().well, .border = .{ .width = 0, .radius = 4 } });
        checkbox.behavior.interaction.a11y.?.label = "选择传输任务";
        checkbox.meta.ownership.meta.test_id = "transfer.task.select";
        try upper.appendChild(cx.allocator, checkbox);
        const color = phaseColor(task_.phase);
        try upper.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get(if (task_.direction == .upload) "arrow-up-right" else "arrow-down-left").?, color, S.icon(14)));
        checkbox.setStyleInline(cx.allocator, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .min_width = 16, .padding = .ZERO, .flex_shrink = 0 });
        const name = try self.label(upper, task_.name, 11.5, 400, false);
        name.setStyleInline(cx.allocator, S.flexibleLabel());
        if (self.options.presentation != .session_popover) {
            const owner = try self.label(upper, task_.owner_label, 10, 400, true);
            owner.setStyleInline(cx.allocator, S.label(106));
            if (owner.getText()) |old| {
                var text_props = old;
                text_props.text_overflow = .ellipsis;
                owner.setText(text_props);
            }
        }
        const status = try self.label(upper, phaseLabel(task_.phase), 10.5, 500, true);
        status.setTextColor(color);
        status.setStyleInline(cx.allocator, S.label(76));
        var buffer: [96]u8 = undefined;
        const description = if (task_.phase == .running) try std.fmt.bufPrint(&buffer, "{d:.1} MiB/s", .{@as(f64, @floatFromInt(task_.speed_bps)) / 1048576}) else if (task_.status_detail.len > 0) task_.status_detail else switch (task_.phase) {
            .queued => "等待连接",
            .paused => if (task_.can_resume) "等待继续" else "数据已保留",
            else => "",
        };
        const rate = try self.label(upper, description, 10, 400, true);
        rate.setStyleInline(cx.allocator, S.label(112));
        if (rate.getText()) |old| {
            var text_props = old;
            text_props.text_align = .end;
            rate.setText(text_props);
        }
        const actions = try ui.box(cx, S.row(24, 2), .{});
        actions.style.width = .{ .px = 76 };
        try upper.appendChild(cx.allocator, actions);
        if (primaryAction(task_.phase)) |action| {
            _ = try self.button(actions, scope, actionLabel(action, task_.direction), "transfer.task.primary", actionIcon(action, task_.direction), .{ .panel = self, .target = task_.target, .action = action }, !self.actionAvailable(task_.target) or (action == .resume_transfer and !task_.can_resume), 24);
        } else {
            const slot = try ui.box(cx, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .align_items = .center, .justify = .center, .flex_shrink = 0 }, .{});
            try slot.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get(if (task_.phase == .queued or task_.phase == .retry_wait) "clock" else if (task_.phase == .verifying or task_.phase == .pausing or task_.phase == .cancelling) "loader-circle" else "minus").?, S.theme.current().fg_3, S.icon(16)));
            try actions.appendChild(cx.allocator, slot);
        }
        _ = try self.button(actions, scope, "查看任务详情", "transfer.task.more", "ellipsis", .{ .panel = self, .target = task_.target, .kind = .detail }, false, 24);
        _ = try self.button(actions, scope, if (expanded) "收起任务详情" else "展开任务详情", "transfer.task.expand", if (expanded) "chevron-up" else "chevron-down", .{ .panel = self, .target = task_.target, .kind = .detail }, false, 24);
        const lower = try ui.box(cx, S.row(14, 6), .{});
        try row.appendChild(cx.allocator, lower);
        const progress = try self.label(lower, "", 9.5, 400, true);
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
        progress.setStyleInline(cx.allocator, .{ .width = .{ .px = 270 }, .min_width = 0, .flex_shrink = 1 });
        const path = try self.label(lower, task_.remote_path, 9.5, 400, true);
        path.setStyleInline(cx.allocator, S.flexibleLabel());
        if (path.getText()) |old| {
            var text_props = old;
            text_props.text_align = .end;
            path.setText(text_props);
        }
        if (category(task_.phase) != .ended) {
            const track = try ui.box(cx, S.track(), .{});
            try row.appendChild(cx.allocator, track);
            const fraction: f64 = if (task_.total_bytes) |total| if (total > 0) @min(@as(f64, 1), @as(f64, @floatFromInt(task_.done_bytes)) / @as(f64, @floatFromInt(total))) else 0 else 0;
            try track.appendChild(cx.allocator, try ui.box(cx, S.fill(@floatCast(fraction), color), .{}));
        }
        if (expanded) try self.renderDetail(root, scope, task_);
        return root;
    }
    fn renderDetail(self: *Panel, root: *ui.Node, scope: *ui.Scope, task_: Task) !void {
        const detail_box = try ui.box(self.cx, S.detail(), .{});
        try root.appendChild(self.cx.allocator, detail_box);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, self.cx);
        scroll.container.setStyleInline(self.cx.allocator, S.viewport());
        scroll.content.setStyleInline(self.cx.allocator, .{ .direction = .column, .gap = 4 });
        try detail_box.appendChild(self.cx.allocator, scroll.container);
        inline for (.{ .{ "本地", "local_path" }, .{ "远程", "remote_path" } }) |field| {
            const node = try self.label(scroll.content, "", 10.5, 400, true);
            try self.format(node, "{s}  {s}", .{ field[0], @field(task_, field[1]) });
            node.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 17 }, .flex_shrink = 0, .overflow = .hidden });
        }
        const title = try self.label(scroll.content, "", 10.5, 400, true);
        if (task_.route.len == 0) try self.format(title, "任务 #{d} · {s}", .{ task_.target.job, task_.owner_label }) else try self.format(title, "任务 #{d} · {s} · {s}", .{ task_.target.job, task_.owner_label, task_.route });
        title.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 17 }, .flex_shrink = 0 });
        const options = try self.label(scroll.content, task_.options, 10.5, 400, true);
        options.setTextColor(S.theme.current().accent_ink);
        options.setStyleInline(self.cx.allocator, .{ .height = .{ .px = 17 }, .flex_shrink = 0 });
        const summary = try self.label(scroll.content, task_.event_summary, 10.5, 400, true);
        summary.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 17 }, .flex_shrink = 0, .overflow = .hidden });
        const actions = try ui.box(self.cx, S.row(28, 6), .{});
        try scroll.content.appendChild(self.cx.allocator, actions);
        try actions.appendChild(self.cx.allocator, try ui.spacer(self.cx));
        _ = try self.button(actions, scope, "复制远程路径", "transfer.task.copy_path", "copy", .{ .panel = self, .target = task_.target, .kind = .copy_path }, false, 28);
        _ = try self.button(actions, scope, "查看任务事件", "transfer.task.events", "list", .{ .panel = self, .target = task_.target, .kind = .events }, false, 28);
        _ = try self.button(actions, scope, "收起任务详情", "transfer.task.collapse", "chevron-up", .{ .panel = self, .target = task_.target, .kind = .detail }, false, 28);
    }

    fn itemHeight(index: usize, raw: ?*anyopaque) f32 {
        const p: *Panel = @ptrCast(@alignCast(raw.?));
        if (p.source == null or index >= p.visible.items.len) return S.row_pitch;
        return if (p.expanded != null and same(p.expanded.?, p.source.?.value.rows[p.visible.items[index]].target)) S.detail_height + 2 else S.row_pitch;
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
    fn actionAvailable(self: *const Panel, target: Target) bool {
        return target.owner != null and (self.manager != null or self.hooks.action != null);
    }
    pub fn perform(self: *Panel, target: Target, action: TaskAction) !void {
        const task_ = self.task(target) orelse return error.StaleTask;
        if (!allows(task_.phase, action)) return error.ActionUnavailable;
        if (action == .resume_transfer and !task_.can_resume) return error.ActionUnavailable;
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
        self.failure.setTextColor(S.theme.current().danger_ink);
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
    pub fn setFilter(self: *Panel, filter: Filter) void {
        self.filter = filter;
        self.invalidate();
    }
    pub fn show(self: *Panel) void {
        self.root.setDisplay(.flex);
        self.cx.requestRedraw();
    }
    /// Context switches must not return focus to the previous session's trigger.
    pub fn dismiss(self: *Panel) void {
        if (self.event_view) |view| view.close();
        self.cx.invalidateReferencesTo(self.root);
        self.root.setDisplay(.none);
        self.cx.requestRedraw();
    }
    pub fn hide(self: *Panel) void {
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
        S.repaint(self.root, self.paint_colors);
        self.paint_colors = S.theme.current();
        self.root.setStyleInline(self.cx.allocator, S.panel(self.options.presentation != .session_popover));
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
            row.* = .{ .target = .{ .job = p.job, .attempt = p.attempt, .owner = if (self.callbacks.?.owner) |resolve| resolve(self.callbacks.?.context, p.job) else if (session == 0) null else .{ .session_id = @fromBackingInt(session) } }, .direction = spec.direction, .name = name, .owner_label = if (session == 0) "归属未知" else try std.fmt.allocPrint(a, "会话 #{d}", .{session}), .local_path = if (spec.direction == .upload) original else try std.fs.path.join(a, &.{ spec.local_dir, name }), .remote_path = if (spec.direction == .download) original else try std.fs.path.join(a, &.{ spec.remote_dir, name }), .phase = if (p.job_cleanup == .unknown) .cleanup_unknown else if (p.state == .failed and p.failure == .checksum) .checksum_failed else std.meta.stringToEnum(Phase, @tagName(p.state)).?, .done_bytes = p.done_bytes, .total_bytes = if (p.total_bytes == 0 and p.state != .succeeded) null else p.total_bytes, .speed_bps = p.speed_bps, .status_detail = if (p.failure) |failure| failureLabel(failure) else "", .route = if (self.callbacks.?.metadata) |call| call(self.callbacks.?.context, p.job) else "", .options = try std.fmt.allocPrint(a, "断点续传 {s} · MD5 {s}", .{ if (spec.resume_transfer) "开" else "关", if (spec.md5_check) "开" else "关" }) };
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
        for (rows) |row| if (row.target.owner) |owner| {
            var exists = false;
            for (choices.items) |choice| if (scopeEql(choice.scope, .{ .session = owner })) {
                exists = true;
                break;
            };
            if (!exists) try choices.append(a, .{ .label = row.owner_label, .scope = .{ .session = owner } });
        };
        if (self.callbacks.?.scope_choices) |extra| try choices.appendSlice(a, try extra(self.callbacks.?.context, a));
        var selected: Scope = if (self.options.presentation == .session_popover) self.selected_scope else .all;
        var scope_label: []const u8 = if (self.options.presentation == .session_popover) (if (self.selected_scope == .sessions) "当前组" else "当前会话") else "全部会话";
        for (choices.items) |choice| if (scopeEql(choice.scope, self.selected_scope)) {
            selected = choice.scope;
            scope_label = choice.label;
            break;
        };
        try self.update(.{ .revision = self.revision + 1, .rows = rows, .choices = choices.items, .scope = selected, .scope_label = scope_label });
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
        if (p.options.presentation == .window) {
            const available_width = @max(0, bounds.w - parent.style.padding.left - parent.style.padding.right);
            const available_height = @max(0, bounds.h - parent.style.padding.top - parent.style.padding.bottom);
            const width = if (p.options.fill_window) available_width else @min(@as(f32, 840), available_width);
            const height = if (p.options.fill_window) available_height else @min(@as(f32, 578), available_height);
            if (p.root.style.width == .px and p.root.style.height == .px and p.root.style.width.px == width and p.root.style.height.px == height) return .done;
            p.root.setStyleInline(p.cx.allocator, .{ .width = .{ .px = width }, .height = .{ .px = height } });
            return .needs_layout;
        }
        const global = p.options.presentation == .global_popover;
        const width = @max(@as(f32, 1), @min(@as(f32, if (global) 840 else 620), bounds.w - 16));
        var height = @max(@as(f32, 1), @min(@as(f32, if (global) 578 else 330), bounds.h - 16));
        var top: f32 = 46;
        var right: f32 = 14;
        if (p.anchor_id) |id| {
            if (findNode(p.cx.root orelse return .done, id)) |anchor| {
                const r = anchor.globalRect();
                top = if (global) r.y - bounds.y + r.h + 4 else r.y - bounds.y - height - 9;
                right = bounds.x + bounds.w - r.x - r.w;
            } else {
                p.hide();
                return .done;
            }
        }
        // The titlebar list stays below its trigger in compact windows; its
        // existing task viewport absorbs the height reduction.
        if (global) height = @max(@as(f32, 1), @min(height, bounds.h - @max(@as(f32, 8), top) - 8));
        top = std.math.clamp(top, @as(f32, 8), @max(@as(f32, 8), bounds.h - height - 8));
        right = std.math.clamp(right, @as(f32, 8), @max(@as(f32, 8), bounds.w - width - 8));
        const ext = p.root.style.ensureExtPanic(p.cx.allocator);
        if (p.root.style.width.px == width and p.root.style.height.px == height and ext.inset.top.px == top and ext.inset.right.px == right) return .done;
        p.root.setStyleInline(p.cx.allocator, .{ .width = .{ .px = width }, .height = .{ .px = height }, .inset = .{ .top = .{ .px = top }, .right = .{ .px = right } } });
        return .needs_layout;
    }
};
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
