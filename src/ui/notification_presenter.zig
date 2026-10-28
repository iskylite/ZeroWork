//! One host-owned toast overlay per window, outside workspace/content clips.
//! Uses public Zenit nodes and Button for focus/key/hit semantics. Updates keep
//! the three slot nodes alive; dismissal never destroys an executing handler.
const std = @import("std");
const ui = @import("ui");
const host = @import("../host/notification_host.zig");
const notifications = host.notifications;
const S = @import("notification_styles.zig");
const theme = @import("app_theme.zig");
const layout = @import("notification_placement.zig");
const Slot = struct {
    presenter: *Presenter,
    fact_id: ?u64 = null,
    revision: u64 = 0,
    root: *ui.Node,
    icons: [4]*ui.Node,
    title: *ui.Node,
    detail: *ui.Node,
    source: *ui.Node,
    footer: *ui.Node,
    status_tag: *ui.Node,
    status_label: *ui.Node,
    countdown: *ui.Node,
    close: *ui.Node,
    actions: [3]Action,
    action_row: *ui.Node,
    expand: *ui.Node,
    expanded: bool = false,
    hovered: bool = false,
    obscured: bool = false,
    fn dismiss(self: *Slot) void {
        if (self.fact_id) |id| self.presenter.host.coordinator.dismissNotification(id);
        self.presenter.cx.requestRedraw();
    }
    fn toggle(self: *Slot) void {
        self.expanded = !self.expanded;
        self.revision = 0;
        self.presenter.cx.requestRedraw();
    }
    fn enter(self: *Slot) void {
        self.hovered = true;
    }
    fn leave(self: *Slot) void {
        self.hovered = false;
    }
};
const Action = struct {
    slot: *Slot,
    index: usize,
    root: *ui.Node,
    label: *ui.Node,
    fn invoke(self: *Action) void {
        if (self.slot.fact_id) |id| {
            self.slot.presenter.host.dispatchAction(id, self.index) catch return;
            self.slot.presenter.host.coordinator.dismissNotification(id);
            self.slot.presenter.cx.requestRedraw();
        }
    }
};
pub const Placement = struct {
    /// App bounds (the V3 #app), independent of sidebar/content layout.
    content: ui.ComputedRect,
    /// Already open popovers and captured-pointer areas in window coordinates.
    avoid: []const ui.ComputedRect = &.{},
};
pub const Presenter = struct {
    cx: *ui.Cx,
    host: *host.Host,
    window_id: host.WindowId,
    root: *ui.Node,
    viewport: *ui.Node,
    content: *ui.Node,
    slots: [3]Slot = undefined,
    colors: ?theme.Colors = null,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, notification_host: *host.Host, window_id: host.WindowId) !*Presenter {
        const portal = try cx.ensurePopoverPortalRoot();
        for (portal.children.items) |child| if (child.meta.ownership.meta.component_name) |name| if (std.mem.eql(u8, name, "HostNotificationPresenter")) return error.NotificationPresenterAlreadyMounted;
        const root = try ui.boxStyled(cx, S.overlay, .{});
        errdefer cx.destroyDetached(root);
        root.meta.ownership.meta.component_name = "HostNotificationPresenter";
        root.meta.ownership.meta.test_id = "notifications.presenter";
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 0 }, .flex_shrink = 0 });
        scroll.container.meta.ownership.meta.test_id = "notifications.viewport";
        scroll.content.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = S.gap, .flex_shrink = 0 });
        try root.appendChild(cx.allocator, scroll.container);
        const self = try cx.bindState(Presenter, .{ .cx = cx, .host = notification_host, .window_id = window_id, .root = root, .viewport = scroll.container, .content = scroll.content });
        for (&self.slots, 0..) |*slot, i| {
            const card = try ui.boxStyled(cx, S.card, .{});
            card.setDisplay(.none);
            card.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
            card.meta.ownership.meta.test_id = switch (i) {
                0 => "notifications.toast.0",
                1 => "notifications.toast.1",
                else => "notifications.toast.2",
            };
            const header = try ui.boxStyled(cx, S.header, .{});
            try card.appendChild(cx.allocator, header);
            var icons: [4]*ui.Node = undefined;
            const assets = [_]ui.SvgAsset{ ui.icons.info, ui.icons.circle_check, ui.icons.triangle_alert, ui.icons.circle_alert };
            const colors = [_]ui.Color{ theme.current().fg_2, theme.current().ok, theme.current().warn, theme.current().danger };
            for (&icons, 0..) |*icon, j| {
                icon.* = try ui.iconTint(cx, assets[j], colors[j], S.icon());
                try header.appendChild(cx.allocator, icon.*);
                icon.*.setDisplay(.none);
            }
            const title = try ui.textStyled(cx, S.title, "");
            title.meta.ownership.meta.test_id = "notifications.title";
            title.setStyleInline(cx.allocator, S.textBox(cx.tokens));
            try header.appendChild(cx.allocator, title);
            const close = try ui.widgets.Button(.{ .icon_only = true, .a11y_label = "关闭提示", .variant = .ghost, .base_style = S.close(cx.tokens), .on_click = cx.on(Slot, slot, Slot.dismiss) }).mount(scope, cx);
            close.setStyleInline(cx.allocator, S.close(cx.tokens));
            try close.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.x, theme.current().fg_2, S.closeIcon()));
            close.meta.ownership.meta.test_id = switch (i) {
                0 => "notifications.dismiss.0",
                1 => "notifications.dismiss.1",
                else => "notifications.dismiss.2",
            };
            try header.appendChild(cx.allocator, close);
            const body = try ui.boxStyled(cx, S.body, .{});
            try card.appendChild(cx.allocator, body);
            const source = try ui.textStyled(cx, S.line, "");
            source.setStyleInline(cx.allocator, S.lineBox(cx.tokens));
            const secondary = try ui.box(cx, .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = 6, .min_width = 0, .height = .{ .px = 22 }, .flex_shrink = 0 }, .{});
            try body.appendChild(cx.allocator, secondary);
            source.setStyleInline(cx.allocator, .{ .flex = 1, .height = .{ .px = 18 } });
            try secondary.appendChild(cx.allocator, source);
            const expand = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.chevron_down, .icon_size = @as(f32, 12), .variant = .ghost, .a11y_label = "展开通知详情", .base_style = @import("notification_history_styles.zig").expand(), .on_click = cx.on(Slot, slot, Slot.toggle) }).mount(scope, cx);
            expand.meta.ownership.meta.test_id = "notifications.expand";
            source.meta.ownership.meta.test_id = "notifications.metadata";
            const detail = try ui.textStyled(cx, S.detail, "");
            detail.meta.ownership.meta.test_id = "notifications.detail";
            detail.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .height = .{ .fit = .{} }, .flex_shrink = 0 });
            try body.appendChild(cx.allocator, detail);
            const footer = try ui.boxStyled(cx, S.footer, .{});
            try body.appendChild(cx.allocator, footer);
            const status_tag = try ui.box(cx, S.statusTag(0), .{});
            const status_label = try ui.textStyled(cx, S.line, "");
            try status_tag.appendChild(cx.allocator, status_label);
            try footer.appendChild(cx.allocator, status_tag);
            const countdown = try ui.textStyled(cx, S.line, "");
            countdown.meta.ownership.meta.test_id = "notifications.countdown";
            countdown.setStyleInline(cx.allocator, .{ .width = .{ .px = 64 }, .min_width = 64, .height = .{ .px = 18 }, .flex_shrink = 0 });
            const action_row = try ui.boxStyled(cx, S.actions, .{});
            try footer.appendChild(cx.allocator, action_row);
            try header.insertChildBefore(cx.allocator, countdown, close);
            try secondary.appendChild(cx.allocator, expand);
            slot.* = .{ .presenter = self, .root = card, .icons = icons, .title = title, .detail = detail, .source = source, .footer = footer, .status_tag = status_tag, .status_label = status_label, .countdown = countdown, .close = close, .action_row = action_row, .actions = undefined, .expand = expand };
            card.behavior.events.on_hover = cx.on(Slot, slot, Slot.enter);
            card.behavior.events.on_leave = cx.on(Slot, slot, Slot.leave);
            inline for (&slot.actions, 0..) |*action, j| {
                const button = try ui.widgets.Button(.{ .a11y_label = "通知操作", .variant = if (j == 0) .primary else .secondary, .size = .xs, .base_style = @import("notification_history_styles.zig").action(), .hover_style = .{ .background = theme.current().hover }, .on_click = cx.on(Action, action, Action.invoke) }).mount(scope, cx);
                const label = try ui.textStyled(cx, S.actionLabel, "");
                label.setTextColor(theme.current().accent_ink);
                label.setStyleInline(cx.allocator, .{ .height = .{ .px = 18 }, .min_width = 0, .flex_shrink = 1 });
                try button.appendChild(cx.allocator, label);
                action.* = .{ .slot = slot, .index = j, .root = button, .label = label };
                button.meta.ownership.meta.test_id = "notifications.action";
                if (j == 0) try secondary.insertChildBefore(cx.allocator, button, expand) else try action_row.appendChild(cx.allocator, button);
                button.setDisplay(.none);
            }
            try scroll.content.appendChild(cx.allocator, card);
        }
        try portal.appendChild(cx.allocator, root);
        return self;
    }
    /// Call at the existing safe frame boundary. This never changes focus.
    /// Geometry belongs to the window host and is not supplied by plugins.
    pub fn update(self: *Presenter, now_ms: u64, window_focused: bool, active_owner: ?notifications.Owner, placement: Placement) !void {
        if (window_focused) if (active_owner) |owner| {
            _ = self.host.coordinator.markNotificationsRead(owner);
        };
        for (&self.slots) |*slot| if (slot.fact_id) |id| {
            const keyboard = if (self.cx.focus_manager.getFocused()) |focused| focused == slot.root or focused.isDescendantOf(slot.root) else false;
            self.host.coordinator.pauseNotification(id, slot.hovered or keyboard or slot.obscured or slot.expanded);
        };
        const colors = theme.current();
        const theme_changed = self.colors == null or !std.meta.eql(self.colors.?, colors);
        self.colors = colors;
        if (theme_changed) for (&self.slots) |*slot| {
            const inks = [_]ui.Color{ colors.fg_2, colors.ok_ink, colors.warn_ink, colors.danger_ink };
            for (slot.icons, 0..) |icon, index| _ = icon.setTint(inks[index]);
            slot.title.setTextColor(colors.fg_1);
            slot.source.setTextColor(colors.fg_2);
            slot.detail.setTextColor(colors.fg_2);
            slot.countdown.setTextColor(colors.fg_2);
            for (slot.actions) |action| action.label.setTextColor(colors.accent_ink);
        };
        var records: [3]*const notifications.NotificationRecord = undefined;
        const count = self.host.coordinator.visibleNotifications(@backingInt(self.window_id), now_ms, window_focused, &records);
        const available = @max(0, placement.content.w - 2 * layout.edge);
        const width = @min(S.width, available);
        self.root.setStyle(self.cx.allocator, .width, .{ .px = width });
        for (&self.slots, 0..) |*slot, i| {
            if (i >= count or width <= 0) {
                slot.root.setDisplay(.none);
                slot.fact_id = null;
                continue;
            }
            const record = records[i];
            const detail = @import("notification_card.zig").extraDetail(record.event);
            const tagged = false;
            slot.action_row.setStyle(self.cx.allocator, .flex_wrap, if (record.event.actions.len > 1) .wrap else .no_wrap);
            const action_width = @max(1, width - 34 - 22 - (if (tagged) @as(f32, 76) else 0) - (if (!record.persistent()) @as(f32, 68) else 0));
            for (&slot.actions) |*action| {
                action.root.setStyle(self.cx.allocator, .max_width, action_width);
                action.label.setStyle(self.cx.allocator, .max_width, @max(1, action_width - 20));
            }
            if (theme_changed or slot.fact_id != record.fact_id or slot.revision != record.event.event_revision) {
                if (slot.fact_id != record.fact_id) slot.expanded = false;
                slot.fact_id = record.fact_id;
                slot.revision = record.event.event_revision;
                slot.root.behavior.interaction.a11y = .{ .role = if (record.persistent()) .alert else .status, .live = if (record.persistent()) "assertive" else "polite" };
                // Toasts remain a compact preview even without actions. The
                // history expansion retains the complete title and details.
                try setLine(self.cx, slot.title, record.event.title);
                try setLine(self.cx, slot.detail, record.event.detail);
                slot.detail.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .flex_shrink = 0 });
                if (slot.detail.getText()) |text| {
                    var wrapped = text;
                    wrapped.wrap = .word;
                    wrapped.text_overflow = .clip;
                    slot.detail.setText(wrapped);
                }
                try slot.status_label.setTextContent(self.cx.allocator, statusLabel(record.event));
                slot.status_tag.setStyleInline(self.cx.allocator, S.statusTag(@backingInt(record.event.severity)));
                slot.status_label.setTextColor(S.statusInk(@backingInt(record.event.severity)));
                slot.status_tag.setDisplay(if (tagged) .flex else .none);
                slot.footer.setDisplay(if (slot.expanded and record.event.actions.len > 1) .flex else .none);
                slot.detail.setDisplay(if (slot.expanded and detail.len != 0) .flex else .none);
                slot.expand.setDisplay(if (detail.len > 0 or record.event.actions.len > 1) .flex else .none);
                slot.expand.setStyle(self.cx.allocator, .rotate, if (slot.expanded) @as(f32, std.math.pi) else @as(f32, 0));
                if (slot.expand.behavior.interaction.a11y) |*attrs| {
                    attrs.expanded = slot.expanded;
                    attrs.label = if (slot.expanded) "收起通知详情" else "展开通知详情";
                }
                for (slot.icons, 0..) |icon, j| icon.setDisplay(if (j == @backingInt(record.event.severity)) .flex else .none);
                for (&slot.actions, 0..) |*action, j| {
                    if (j >= record.event.actions.len) {
                        action.root.setDisplay(.none);
                        continue;
                    }
                    try action.label.setTextContent(self.cx.allocator, record.event.actions[j].label);
                    action.root.behavior.interaction.a11y = .{ .role = .button, .label = action.label.getText().?.content };
                    action.root.setDisplay(if (j == 0 or slot.expanded) .flex else .none);
                }
                slot.action_row.setDisplay(if (record.event.actions.len == 0 and record.persistent()) .none else .flex);
            }
            slot.countdown.setDisplay(if (record.persistent()) .none else .flex);
            if (!record.persistent()) {
                var remaining: [64]u8 = undefined;
                const text = try std.fmt.bufPrint(&remaining, "{d} 秒后关闭", .{(record.remaining_ms + 999) / 1000});
                try slot.countdown.setTextContent(self.cx.allocator, text);
            }
            const identified = try @import("notification_card.zig").summary(self.cx.allocator, record.event, record.owner_ended);
            defer self.cx.allocator.free(identified);
            try setLine(self.cx, slot.source, identified);
            slot.source.setDisplay(if (identified.len == 0) .none else .flex);
            slot.root.setDisplay(.flex);
        }
        // Measure the currently visible slots. Text/width changes settle after
        // layout; the existing notification timer corrects that next-frame size.
        var height: f32 = 0;
        for (self.slots[0..count]) |slot| {
            const measured = slot.root.globalRect().h;
            height += if (measured > 0) measured else 45;
        }
        height += @as(f32, @floatFromInt(count -| 1)) * S.gap;
        var obstacles: [32]layout.Rect = undefined;
        const obstacle_count = @min(obstacles.len, placement.avoid.len);
        for (placement.avoid[0..obstacle_count], obstacles[0..obstacle_count]) |rect, *obstacle| {
            obstacle.* = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
        }
        const content = placement.content;
        // A stack can contain three maximum-length persistent facts. Preserve
        // their content behind a native scroll viewport instead of overflowing.
        const origin = @min(layout.top, @max(layout.clearance, content.h - 2 * layout.clearance));
        const viewport_height = @min(height, @max(0, content.h - origin - layout.clearance));
        self.viewport.setStyle(self.cx.allocator, .height, .{ .px = viewport_height });
        const position = layout.position(.{ .x = content.x, .y = content.y, .w = content.w, .h = content.h }, width, viewport_height, obstacles[0..obstacle_count]);
        self.root.setStyle(self.cx.allocator, .inset, .{ .left = .{ .px = position.x }, .top = .{ .px = position.y } });
        var covered = false;
        for (obstacles[0..obstacle_count]) |obstacle| {
            if (obstacle.w > 0 and obstacle.h > 0 and !layout.separated(position, obstacle)) {
                covered = true;
                break;
            }
        }
        for (self.slots[0..count], records[0..count]) |*slot, record| {
            slot.obscured = covered;
            slot.root.setOpacityRaw(if (slot.obscured) 0 else 1);
            slot.root.setStyle(self.cx.allocator, .hit_behavior, if (slot.obscured) .pass_through else .@"opaque");
            self.host.coordinator.pauseNotification(record.fact_id, slot.hovered or slot.obscured or slot.expanded or (if (self.cx.focus_manager.getFocused()) |focused| focused == slot.root or focused.isDescendantOf(slot.root) else false));
        }

        self.root.setDisplay(if (covered or count == 0) .none else .flex);
        if (count != 0) self.cx.scheduleRedrawAfterNs(100 * std.time.ns_per_ms);
    }
};
// One Cx-owned local receipt per window. The trigger rectangle is copied before
// controls rebuild; no node from a disposed pane is retained.
const LocalReceipt = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    label: *ui.Node,
    anchor: ui.ComputedRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    viewport: ui.ComputedRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    expires_ms: u64 = 0,
    fn frame(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *LocalReceipt = @ptrCast(@alignCast(raw));
        if (self.expires_ms == 0) return .done;
        const now = (host.localClock() catch return .done).monotonic_ms;
        const bounds = (self.cx.root orelse return .done).globalRect();
        if (now >= self.expires_ms or bounds.w != self.viewport.w or bounds.h != self.viewport.h) {
            self.root.setDisplay(.none);
            self.expires_ms = 0;
            return .done;
        }
        const rect = self.root.globalRect();
        const x = std.math.clamp(self.anchor.x, bounds.x + 8, @max(bounds.x + 8, bounds.x + bounds.w - rect.w - 8));
        const above = self.anchor.y - rect.h - 8;
        const y = std.math.clamp(if (above >= bounds.y + 8) above else self.anchor.y + self.anchor.h + 8, bounds.y + 8, @max(bounds.y + 8, bounds.y + bounds.h - rect.h - 8));
        self.root.setStyle(self.cx.allocator, .inset, .{ .left = .{ .px = x }, .top = .{ .px = y } });
        self.cx.scheduleRedrawAfterNs((self.expires_ms - now) * std.time.ns_per_ms);
        return if (@abs(rect.x - x) > 0.1 or @abs(rect.y - y) > 0.1) .needs_layout else .done;
    }
};
const LocalReceiptSlot = struct { value: ?*LocalReceipt = null };
/// Present a successful local operation at its actual captured trigger. The
/// caller owns outcome/owner validation and must not also publish globally.
pub fn acknowledgeAt(cx: *ui.Cx, anchor: ui.ComputedRect, message: []const u8) !void {
    if (anchor.w <= 0 or anchor.h <= 0 or message.len == 0) return error.InvalidAcknowledgmentAnchor;
    const slot = try cx.state(LocalReceiptSlot, std.hash.Wyhash.hash(0, "ZeroWork.localFeedback"), .{});
    if (slot.value == null) {
        const root = try ui.box(cx, .{ .position = .absolute, .direction = .row, .width = .{ .fit = .{} }, .height = .{ .fit = .{} }, .max_width = 280, .padding = .{ .left = 10, .right = 10, .top = 7, .bottom = 7 }, .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .width = 1, .color = theme.current().border, .radius = 9 }, .shadow = .{ .color = theme.current().shadow, .blur = 28, .offset_y = 10 }, .hit_behavior = .pass_through, .z_index = 150 }, .{});
        root.meta.ownership.meta.test_id = "notifications.local";
        root.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
        const label = try ui.textStyled(cx, S.actionLabel, "");
        try root.appendChild(cx.allocator, label);
        try (try cx.ensurePopoverPortalRoot()).appendChild(cx.allocator, root);
        const value = try cx.bindState(LocalReceipt, .{ .cx = cx, .root = root, .label = label });
        try cx.addAfterLayoutHook(value, LocalReceipt.frame);
        slot.value = value;
    }
    const value = slot.value.?;
    value.anchor = anchor;
    value.viewport = (cx.root orelse return error.NoAcknowledgmentWindow).globalRect();
    value.expires_ms = (try host.localClock()).monotonic_ms + 2000;
    try value.label.setTextContent(cx.allocator, message);
    value.label.setTextColor(theme.current().fg_1);
    value.root.setStyleInline(cx.allocator, .{ .background = theme.current().overlay, .glass = theme.overlayGlass() });
    value.root.setDisplay(.flex);
    cx.requestRedraw();
}

fn setLine(cx: *ui.Cx, node: *ui.Node, text: []const u8) !void {
    const line = try cx.allocator.dupe(u8, text);
    defer cx.allocator.free(line);
    for (line) |*byte| if (byte.* == '\n' or byte.* == '\r' or byte.* == '\t') {
        byte.* = ' ';
    };
    try node.setTextContent(cx.allocator, line);
}
fn statusLabel(event: notifications.NotificationEvent) []const u8 {
    return switch (event.phase) {
        .succeeded => if (std.mem.eql(u8, event.definition_id, "host.reconnect")) "已恢复" else "已完成",
        .failed => "失败",
        .cancelled => if (std.mem.eql(u8, event.definition_id, "host.transfer_done")) "已取消" else "已停止",
        .outcome_unknown => "待核查",
        .accepted => if (std.mem.eql(u8, event.definition_id, "host.reconnect")) "已断开" else "进行中",
        .verifying => "核查中",
    };
}
