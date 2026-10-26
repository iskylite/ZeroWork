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
    close: *ui.Node,
    actions: [3]Action,
    action_row: *ui.Node,
    hovered: bool = false,
    obscured: bool = false,
    fn dismiss(self: *Slot) void {
        if (self.fact_id) |id| self.presenter.host.coordinator.dismissNotification(id);
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
            var icons: [4]*ui.Node = undefined;
            const assets = [_]ui.SvgAsset{ ui.icons.info, ui.icons.circle_check, ui.icons.triangle_alert, ui.icons.circle_alert };
            const colors = [_]ui.Color{ theme.current().fg_2, theme.current().ok, theme.current().warn, theme.current().danger };
            for (&icons, 0..) |*icon, j| {
                icon.* = try ui.iconTint(cx, assets[j], colors[j], S.icon());
                try card.appendChild(cx.allocator, icon.*);
                icon.*.setDisplay(.none);
            }
            try card.appendChild(cx.allocator, header);
            const title = try ui.textStyled(cx, S.title, "");
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
            try card.appendChild(cx.allocator, close);
            const source = try ui.textStyled(cx, S.detail, "");
            source.setStyleInline(cx.allocator, S.textBox(cx.tokens));
            try header.appendChild(cx.allocator, source);
            const detail = try ui.textStyled(cx, S.detail, "");
            detail.setStyleInline(cx.allocator, S.textBox(cx.tokens));
            try header.appendChild(cx.allocator, detail);
            const action_row = try ui.boxStyled(cx, S.actions, .{});
            try header.appendChild(cx.allocator, action_row);
            slot.* = .{ .presenter = self, .root = card, .icons = icons, .title = title, .detail = detail, .source = source, .close = close, .action_row = action_row, .actions = undefined };
            card.behavior.events.on_hover = cx.on(Slot, slot, Slot.enter);
            card.behavior.events.on_leave = cx.on(Slot, slot, Slot.leave);
            for (&slot.actions, 0..) |*action, j| {
                const button = try ui.widgets.Button(.{ .a11y_label = "通知操作", .variant = .ghost, .size = .xs, .base_style = S.action(cx.tokens), .on_click = cx.on(Action, action, Action.invoke) }).mount(scope, cx);
                const label = try ui.textStyled(cx, S.actionLabel, "");
                label.setStyleInline(cx.allocator, .{ .height = .{ .fit = .{} }, .flex_shrink = 0 });
                try button.appendChild(cx.allocator, label);
                action.* = .{ .slot = slot, .index = j, .root = button, .label = label };
                button.meta.ownership.meta.test_id = "notifications.action";
                try action_row.appendChild(cx.allocator, button);
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
            self.host.coordinator.pauseNotification(id, slot.hovered or keyboard or slot.obscured);
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
            // Reserve the existing card insets, icon, close target and gaps.
            const action_width = @max(1, width - (13 * 2 + 16 + 19 + 9 * 2));
            for (&slot.actions) |*action| {
                action.root.setStyle(self.cx.allocator, .max_width, action_width);
                action.label.setStyle(self.cx.allocator, .max_width, @max(1, action_width - 12));
            }
            if (slot.fact_id != record.fact_id or slot.revision != record.event.event_revision) {
                slot.fact_id = record.fact_id;
                slot.revision = record.event.event_revision;
                slot.root.behavior.interaction.a11y = .{ .role = if (record.persistent()) .alert else .status, .live = if (record.persistent()) "assertive" else "polite" };
                try slot.title.setTextContent(self.cx.allocator, record.event.title);
                try slot.detail.setTextContent(self.cx.allocator, record.event.detail);
                slot.detail.setDisplay(if (record.event.detail.len != 0) .flex else .none);
                for (slot.icons, 0..) |icon, j| icon.setDisplay(if (j == @backingInt(record.event.severity)) .flex else .none);
                for (&slot.actions, 0..) |*action, j| {
                    if (j >= record.event.actions.len) {
                        action.root.setDisplay(.none);
                        continue;
                    }
                    try action.label.setTextContent(self.cx.allocator, record.event.actions[j].label);
                    action.root.behavior.interaction.a11y = .{ .role = .button, .label = action.label.getText().?.content };
                    action.root.setDisplay(.flex);
                }
                slot.action_row.setDisplay(if (record.event.actions.len == 0) .none else .flex);
            }
            const background = if (active_owner) |owner| !owner.eql(record.event.owner.content) else true;
            const source = if (record.owner_ended) "所属会话已结束" else if (background) record.event.owner_name else "";
            try slot.source.setTextContent(self.cx.allocator, source);
            slot.source.setDisplay(if (source.len == 0) .none else .flex);
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
            slot.obscured = covered and !record.persistent();
            slot.root.setOpacityRaw(if (slot.obscured) 0 else 1);
            slot.root.setStyle(self.cx.allocator, .hit_behavior, if (slot.obscured) .pass_through else .@"opaque");
            self.host.coordinator.pauseNotification(record.fact_id, slot.hovered or slot.obscured or (if (self.cx.focus_manager.getFocused()) |focused| focused == slot.root or focused.isDescendantOf(slot.root) else false));
        }

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
