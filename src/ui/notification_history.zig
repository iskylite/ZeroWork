//! Bounded process-local history. Callbacks only change state; rows are rebuilt
//! at the safe layout boundary and always dispatch the original fact identity.
const std = @import("std");
const ui = @import("ui");
const host = @import("../host/notification_host.zig");
const S = @import("notification_history_styles.zig");
const feedback = @import("notification_styles.zig");
const theme = @import("app_theme.zig");
const Row = struct { fact_id: u64, age: *ui.Node };
const Expand = struct {
    view: *View,
    fact_id: u64,
    fn toggle(self: *Expand) void {
        self.view.expanded_fact = if (self.view.expanded_fact == self.fact_id) null else self.fact_id;
        self.view.revision = null;
        self.view.pending_detail_focus = self.fact_id;
        self.view.cx.requestRedraw();
    }
};
const Action = struct {
    view: *View,
    fact_id: u64,
    index: usize,
    fn invoke(self: *Action) void {
        self.view.host.dispatchAction(self.fact_id, self.index) catch {
            self.view.failure.setDisplay(.flex);
            self.view.cx.requestRedraw();
            return;
        };
        self.view.host.coordinator.dismissNotification(self.fact_id);
        self.view.open.set(false);
        self.view.cx.requestRedraw();
    }
};
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    host: *host.Host,
    trigger: *ui.Node,
    badge: *ui.Node,
    open: *ui.Signal(bool),
    root: *ui.Node,
    scroll: ui.widgets.ScrollAreaResult,
    failure: *ui.Node,
    clear_button: *ui.Node,
    close_button: *ui.Node = undefined,
    count: *ui.Node = undefined,
    expanded_fact: ?u64 = null,
    pending_detail_focus: ?u64 = null,
    row_scope: ?*ui.Scope = null,
    rows: std.ArrayList(Row) = .empty,
    revision: ?u64 = null,
    age_minute: u64 = std.math.maxInt(u64),
    colors: theme.Colors,
    was_open: bool = false,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, notification_host: *host.Host, trigger: *ui.Node) !*View {
        const open = try scope.createSignal(bool, false);
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .host = notification_host, .trigger = trigger, .badge = undefined, .open = open, .root = undefined, .scroll = undefined, .failure = undefined, .clear_button = undefined, .colors = theme.current() });
        try scope.onCleanup(View, self, cleanup);
        self.badge = try ui.box(cx, .{ .position = .absolute, .inset = .{ .right = .{ .px = 4 }, .top = .{ .px = 3 } }, .width = .{ .px = 6 }, .height = .{ .px = 6 }, .background = theme.current().accent, .border = .{ .radius = 3 } }, .{});
        self.badge.meta.ownership.meta.test_id = "notifications.unread";
        self.badge.setDisplay(.none);
        try trigger.appendChild(cx.allocator, self.badge);
        trigger.behavior.events.on_click = .{ .callback = toggle, .context = self };
        const popup = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .anchor = .{ .node = trigger }, .position = .bottom_end, .offset = .{ .static = 8 }, .width = S.width, .max_width = S.width, .viewport_padding = 12, .constrain_width_to_viewport = true, .shift_main_axis = true, .size_policy = .fit_content, .on_open_change = cx.on(View, self, openChanged) }).mount(scope, cx);
        // Manual anchoring still returns a wrapper owned by the caller.
        // Keep that invisible subtree attached so normal window teardown frees
        // its nodes; the visible content is independently hosted in the portal.
        popup.wrapper.setDisplay(.none);
        try trigger.appendChild(cx.allocator, popup.wrapper);
        self.scope = popup.scope;
        self.root = popup.content;
        self.root.meta.ownership.meta.test_id = "notifications.history";
        self.root.setStyleInline(cx.allocator, S.panel());
        const heading = try ui.box(cx, S.heading(), .{});
        try self.root.appendChild(cx.allocator, heading);
        try heading.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.bell, theme.current().accent_ink, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 }));
        const title = try ui.text(cx, "通知", .{ .font_size = 13, .font_weight = 600, .color = theme.current().fg_1 });
        try heading.appendChild(cx.allocator, title);
        self.count = try ui.text(cx, "0", S.text(true));
        self.count.setStyleInline(cx.allocator, .{ .padding = .{ .left = 7, .right = 7 }, .background = theme.current().selection, .border = .{ .radius = 6 } });
        self.count.meta.ownership.meta.test_id = "notifications.history.count";
        try heading.appendChild(cx.allocator, self.count);
        try heading.appendChild(cx.allocator, try ui.spacer(cx));
        self.clear_button = try ui.widgets.Button(.{ .label = "清空", .variant = .ghost, .size = .xs, .on_click = cx.on(View, self, clear) }).mount(self.scope, cx);
        self.clear_button.meta.ownership.meta.test_id = "notifications.history.clear";
        try heading.appendChild(cx.allocator, self.clear_button);
        const close = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.x, .icon_size = @as(f32, 12), .variant = .ghost, .size = .xs, .a11y_label = "关闭通知列表", .on_click = cx.on(View, self, hide) }).mount(self.scope, cx);
        self.close_button = close;
        close.meta.ownership.meta.test_id = "notifications.history.close";
        try heading.appendChild(cx.allocator, close);
        self.scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(self.scope, cx);
        self.scroll.container.meta.ownership.meta.test_id = "notifications.history.viewport";
        self.scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 320 }, .flex_shrink = 0 });
        self.scroll.content.setStyleInline(cx.allocator, S.column());
        try self.root.appendChild(cx.allocator, self.scroll.container);
        const policy = try ui.text(cx, "仅保留本次运行的最近 100 条", .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().fg_2, .selectable = false });
        policy.setStyleInline(cx.allocator, S.policy());
        try self.root.appendChild(cx.allocator, policy);
        self.failure = try ui.text(cx, "该操作已不可用，请回到会话查看。", S.text(true));
        self.failure.setTextColor(theme.current().warn_ink);
        self.failure.setDisplay(.none);
        try self.root.appendChild(cx.allocator, self.failure);
        try cx.addAfterLayoutHook(self, frame);
        return self;
    }
    fn toggle(raw: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw));
        self.open.set(!self.open.peek());
        self.failure.setDisplay(.none);
        self.cx.requestRedraw();
    }
    fn openChanged(self: *View, _: bool) void {
        if (!self.open.peek() and self.was_open) self.cx.setFocus(self.trigger);
        self.cx.requestRedraw();
    }
    fn hide(self: *View) void {
        self.open.set(false);
        self.cx.setFocus(self.trigger);
        self.cx.requestRedraw();
    }
    fn clear(self: *View) void {
        self.host.coordinator.clearHistory();
        self.expanded_fact = null;
        self.failure.setDisplay(.none);
        self.cx.requestRedraw();
    }
    fn rebuild(self: *View) !void {
        // Clear all focus/interaction references before disposing row handlers.
        for (self.scroll.content.children.items) |node| self.cx.invalidateReferencesTo(node);
        if (self.row_scope) |scope| scope.dispose();
        self.row_scope = null;
        while (self.scroll.content.children.items.len > 0) {
            const node = self.scroll.content.children.items[self.scroll.content.children.items.len - 1];
            self.cx.detachChild(self.scroll.content, node);
            self.cx.destroyDetached(node);
        }
        self.rows.clearRetainingCapacity();
        const scope = try self.scope.childScope();
        self.row_scope = scope;
        const records = self.host.coordinator.notification_records.items;
        self.clear_button.setDisplay(if (records.len > 0) .flex else .none);
        var count_buffer: [16]u8 = undefined;
        try self.count.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&count_buffer, "{d}", .{records.len}));
        if (records.len == 0) {
            const empty = try ui.box(self.cx, S.empty(), .{});
            empty.meta.ownership.meta.test_id = "notifications.history.empty";
            const mark = try ui.box(self.cx, .{ .width = .{ .px = 40 }, .height = .{ .px = 40 }, .align_items = .center, .justify = .center, .background = theme.current().selection, .border = .{ .radius = 12 }, .flex_shrink = 0 }, .{});
            try mark.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.bell, theme.current().accent_ink, .{ .width = .{ .px = 22 }, .height = .{ .px = 22 } }));
            try empty.appendChild(self.cx.allocator, mark);
            try empty.appendChild(self.cx.allocator, try ui.text(self.cx, "暂无通知", .{ .font_size = 13, .font_weight = 500, .color = theme.current().fg_1 }));
            try empty.appendChild(self.cx.allocator, try ui.text(self.cx, "连接与传输的重要动态会显示在这里", S.text(true)));
            try self.scroll.content.appendChild(self.cx.allocator, empty);
        }
        var i = records.len;
        while (i > 0) {
            i -= 1;
            const record = records[i];
            if (i != records.len - 1) {
                const divider = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 1 }, .background = theme.current().border.withAlpha(128), .flex_shrink = 0 }, .{});
                try self.scroll.content.appendChild(self.cx.allocator, divider);
            }
            const card = try ui.box(self.cx, S.row(), .{});
            card.meta.ownership.meta.test_id = "notifications.history.record";
            try self.scroll.content.appendChild(self.cx.allocator, card);
            const main = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 18 }, .direction = .row, .align_items = .center, .gap = 8, .min_width = 0, .flex_shrink = 0 }, .{});
            try card.appendChild(self.cx.allocator, main);
            const assets = [_]ui.SvgAsset{ ui.icons.info, ui.icons.circle_check, ui.icons.triangle_alert, ui.icons.circle_alert };
            try main.appendChild(self.cx.allocator, try ui.iconTint(self.cx, assets[@backingInt(record.event.severity)], feedback.statusInk(@backingInt(record.event.severity)), .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 }));
            const title = try ui.text(self.cx, record.event.title, S.text(false));
            title.meta.ownership.meta.test_id = "notifications.history.title";
            title.setStyleInline(self.cx.allocator, S.line());
            try main.appendChild(self.cx.allocator, title);
            const age = try ui.text(self.cx, "", .{ .font_size = 10.5, .line_height = 18.0 / 10.5, .color = theme.current().fg_2, .selectable = false });
            age.setStyleInline(self.cx.allocator, .{ .height = .{ .px = 18 }, .max_width = 76, .flex_shrink = 0 });
            try main.appendChild(self.cx.allocator, age);
            try self.rows.append(self.cx.allocator, .{ .fact_id = record.fact_id, .age = age });
            const secondary = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 22 }, .padding = .{ .left = 22 }, .direction = .row, .align_items = .center, .gap = 6, .min_width = 0, .flex_shrink = 0 }, .{});
            try card.appendChild(self.cx.allocator, secondary);
            const detail = extraDetail(record.event);
            const first_line = std.mem.trim(u8, detail[0 .. std.mem.indexOfScalar(u8, detail, '\n') orelse detail.len], " \t\r");
            const preview = if (record.event.object_name.len > 0 and !std.mem.eql(u8, record.event.object_name, record.event.owner_name)) record.event.object_name else first_line;
            const summary_text = try std.fmt.allocPrint(self.cx.allocator, "{s}{s}{s}{s}", .{ record.event.owner_name, if (record.event.owner_name.len > 0 and (preview.len > 0 or record.owner_ended)) " · " else "", if (record.owner_ended) "会话已结束" else preview, if (record.owner_ended and preview.len > 0) " · 详情已保留" else "" });
            defer self.cx.allocator.free(summary_text);
            const summary = try ui.text(self.cx, summary_text, S.text(true));
            summary.meta.ownership.meta.test_id = "notifications.history.summary";
            summary.setStyleInline(self.cx.allocator, S.line());
            try secondary.appendChild(self.cx.allocator, summary);
            // The common single action stays inline. Additional actions remain
            // available with the complete content in the expanded section.
            if (record.event.actions.len > 0) try self.mountAction(scope, secondary, record, 0);
            const expandable = detail.len > 0 or record.event.actions.len > 1;
            const expanded = expandable and self.expanded_fact == record.fact_id;
            if (expandable) {
                const expand_handler = try scope.createState(Expand, .{ .view = self, .fact_id = record.fact_id });
                const expand = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = if (expanded) ui.icons.chevron_up else ui.icons.chevron_down, .icon_size = @as(f32, 12), .variant = .ghost, .a11y_label = if (expanded) "收起通知详情" else "展开通知详情", .base_style = S.expand(), .on_click = self.cx.on(Expand, expand_handler, Expand.toggle) }).mount(scope, self.cx);
                expand.meta.ownership.meta.test_id = "notifications.history.expand";
                expand.behavior.interaction.a11y.?.expanded = expanded;
                try secondary.appendChild(self.cx.allocator, expand);
                if (self.pending_detail_focus == record.fact_id) self.cx.setFocus(expand);
            }
            if (expanded) {
                const details = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = .{ .left = 22, .top = 4, .bottom = 2 }, .direction = .column, .gap = 4, .min_width = 0, .flex_shrink = 0 }, .{});
                details.meta.ownership.meta.test_id = "notifications.history.details";
                try card.appendChild(self.cx.allocator, details);
                var text_style = S.text(true);
                text_style.wrap = .word;
                text_style.text_overflow = .clip;
                if (detail.len > 0) {
                    const line = try ui.text(self.cx, detail, text_style);
                    line.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
                    try details.appendChild(self.cx.allocator, line);
                }
                if (record.event.actions.len > 1) {
                    const actions = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .flex_wrap = .wrap, .gap = 6, .flex_shrink = 0 }, .{});
                    try details.appendChild(self.cx.allocator, actions);
                    for (1..record.event.actions.len) |index| try self.mountAction(scope, actions, record, index);
                }
            }
        }
        self.pending_detail_focus = null;
        self.age_minute = std.math.maxInt(u64);
        self.revision = self.host.coordinator.history_revision;
    }
    fn mountAction(self: *View, scope: *ui.Scope, parent: *ui.Node, record: host.notifications.NotificationRecord, index: usize) !void {
        const handler = try scope.createState(Action, .{ .view = self, .fact_id = record.fact_id, .index = index });
        const button = try ui.widgets.Button(.{ .label = record.event.actions[index].label, .variant = .ghost, .size = .xs, .disabled = record.owner_ended, .base_style = S.action(), .hover_style = .{ .background = theme.current().hover }, .on_click = self.cx.on(Action, handler, Action.invoke) }).mount(scope, self.cx);
        button.setStyle(self.cx.allocator, .max_width, @max(1, @min(112, self.root.globalRect().w - 120)));
        button.meta.ownership.meta.test_id = "notifications.history.action";
        try parent.appendChild(self.cx.allocator, button);
    }
    fn frame(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        self.update() catch |err| std.log.debug("notification history: {s}", .{@errorName(err)});
        return .done;
    }
    fn update(self: *View) !void {
        // Blur-only changes do not change palette equality. Keep the retained
        // popover in sync without rebuilding its content or blurring foreground.
        const glass = theme.overlayGlass();
        if (self.root.style.backdrop_blur() != glass.backdrop_blur)
            self.root.setStyleInline(self.cx.allocator, .{ .glass = glass });
        const colors = theme.current();
        if (!std.meta.eql(self.colors, colors)) {
            @import("quick_connect_styles.zig").repaint(self.root, self.colors);
            self.colors = colors;
            self.badge.setBackground(colors.accent);
            self.revision = null;
        }
        const opened = self.open.peek();
        if (opened) {
            if (self.cx.window_active) self.host.coordinator.readHistory();
            if (self.revision == null or self.revision.? != self.host.coordinator.history_revision) try self.rebuild();
            const now = (try host.localClock()).monotonic_ms;
            if (self.age_minute != now / 60000) {
                for (self.rows.items) |row| {
                    const record = self.host.coordinator.recordFor(row.fact_id) orelse continue;
                    const minutes = (now -| record.published_ms) / 60000;
                    var age: [80]u8 = undefined;
                    const age_text = if (minutes == 0) "刚刚" else if (minutes < 60) try std.fmt.bufPrint(&age, "{d} 分钟前", .{minutes}) else try std.fmt.bufPrint(&age, "{d} 小时前", .{minutes / 60});
                    try row.age.setTextContent(self.cx.allocator, age_text);
                }
                self.age_minute = now / 60000;
            }
            const root = self.cx.root orelse return;
            const max_height = @min(320, @max(S.collapsed_height, root.globalRect().h - 140));
            const content_height = self.scroll.content.globalRect().h;
            self.scroll.container.setStyle(self.cx.allocator, .height, .{ .px = @min(max_height, @max(S.collapsed_height, content_height)) });
            if (!self.was_open) self.cx.setFocus(self.close_button);
        }
        self.was_open = opened;
        self.badge.setDisplay(if (self.host.coordinator.unreadHistoryCount() > 0) .flex else .none);
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        self.rows.deinit(self.cx.allocator);
    }
};

// Source and object already have their own summary line. Only independent
// detail text (or additional actions) warrants an expandable section.
fn extraDetail(event: host.notifications.NotificationEvent) []const u8 {
    const detail = std.mem.trim(u8, event.detail, " \t\r\n");
    for ([_][]const u8{ event.title, event.owner_name, event.object_name }) |value| {
        if (std.mem.eql(u8, detail, std.mem.trim(u8, value, " \t\r\n"))) return "";
    }
    return detail;
}
