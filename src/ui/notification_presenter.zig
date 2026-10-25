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
        if (self.slot.fact_id) |id| self.slot.presenter.host.dispatchAction(id, self.index) catch {};
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
    slots: [3]Slot = undefined,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, notification_host: *host.Host, window_id: host.WindowId) !*Presenter {
        const portal = try cx.ensurePopoverPortalRoot();
        for (portal.children.items) |child| if (child.meta.ownership.meta.component_name) |name| if (std.mem.eql(u8, name, "HostNotificationPresenter")) return error.NotificationPresenterAlreadyMounted;
        const root = try ui.boxStyled(cx, S.overlay, .{});
        errdefer cx.destroyDetached(root);
        root.meta.ownership.meta.component_name = "HostNotificationPresenter";
        root.meta.ownership.meta.test_id = "notifications.presenter";
        const self = try cx.bindState(Presenter, .{ .cx = cx, .host = notification_host, .window_id = window_id, .root = root });
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
                const button = try ui.widgets.Button(.{ .label = " ", .variant = .ghost, .size = .xs, .base_style = S.action(cx.tokens), .on_click = cx.on(Action, action, Action.invoke) }).mount(scope, cx);
                action.* = .{ .slot = slot, .index = j, .root = button, .label = textNode(button).? };
                button.meta.ownership.meta.test_id = "notifications.action";
                try action_row.appendChild(cx.allocator, button);
                button.setDisplay(.none);
            }
            try root.appendChild(cx.allocator, card);
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
            self.host.coordinator.pauseNotification(id, slot.hovered or keyboard);
        };
        var records: [3]*const notifications.NotificationRecord = undefined;
        const count = self.host.coordinator.visibleNotifications(@backingInt(self.window_id), now_ms, window_focused, &records);
        const available = @max(0, placement.content.w - 2 * S.edge);
        const width = @min(S.width, available);
        self.root.setStyle(self.cx.allocator, .width, .{ .px = width });
        for (&self.slots, 0..) |*slot, i| {
            if (i >= count or width <= 0) {
                slot.root.setDisplay(.none);
                slot.fact_id = null;
                continue;
            }
            const record = records[i];
            if (slot.fact_id != record.fact_id or slot.revision != record.event.event_revision) {
                slot.fact_id = record.fact_id;
                slot.revision = record.event.event_revision;
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
        const position = layout.position(.{ .x = content.x, .y = content.y, .w = content.w, .h = content.h }, width, height, obstacles[0..obstacle_count]);
        self.root.setStyle(self.cx.allocator, .inset, .{ .left = .{ .px = position.x }, .top = .{ .px = position.y } });
        if (count != 0) self.cx.scheduleRedrawAfterNs(100 * std.time.ns_per_ms);
    }
};
fn textNode(node: *ui.Node) ?*ui.Node {
    if (node.getText() != null) return node;
    for (node.children.items) |child| if (textNode(child)) |found| return found;
    return null;
}
