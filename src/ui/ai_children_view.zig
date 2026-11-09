//! Stable rows keep their child identity while a popover is being operated.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");
const projection = @import("../ai/child_projection.zig");
const Logo = @import("ai_child_logo.zig");
const S = @import("ai_children_styles.zig");
const Header = @import("ai_assistant_header.zig");
const id = @import("../host/identity.zig");
pub const Hooks = struct { context: *anyopaque, select: *const fn (*anyopaque, id.AgentId, u64) void };
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    hooks: Hooks,
    open: *ui.Signal(bool),
    root: *ui.Node,
    content: *ui.Node,
    chrome: *ui.Node,
    painted_colors: theme.Colors,
    button: *ui.Node,
    badge: *ui.Node,
    heading_count: *ui.Node,
    rows: std.ArrayList(*Row) = .empty,
    rows_scope: ?*ui.Scope = null,
    fingerprint: u64 = 0,
    a11y_label: [80]u8 = undefined,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, button: *ui.Node, hooks: Hooks) !*View {
        const open = try scope.createSignal(bool, false);
        const popup = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .anchor = .{ .node = button }, .position = .bottom_start, .offset = .{ .static = 6 }, .width = 400, .max_height = 300, .close_on_escape = true, .close_on_outside_click = true, .constrain_width_to_viewport = true, .flip = true, .viewport_padding = 8 }).mount(scope, cx);
        popup.wrapper.setStyleInline(cx.allocator, .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 } });
        popup.chrome.setStyleInline(cx.allocator, .{ .background = theme.current().overlay, .border = .{ .radius = 12 }, .padding = ui.Padding.all(8) });
        const heading = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .left = 52, .right = 12 }, .flex_shrink = 0 }, .{});
        heading.meta.ownership.meta.test_id = "ai.children.heading";
        const title = try ui.textStyled(cx, S.name, "子智能体");
        title.meta.ownership.meta.test_id = "ai.children.title";
        try heading.appendChild(cx.allocator, title);
        try heading.appendChild(cx.allocator, try ui.spacer(cx));
        const heading_count = try ui.textStyled(cx, S.secondary, "");
        try heading.appendChild(cx.allocator, heading_count);
        try popup.content.appendChild(cx.allocator, heading);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(popup.scope, cx);
        scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{ .max = 252 } }, .max_height = 252, .min_height = 0 });
        scroll.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column });
        scroll.container.meta.ownership.meta.test_id = "ai.children.list";
        try popup.content.appendChild(cx.allocator, scroll.container);
        const badge = try Header.mountCountBadge(cx, button, "ai.children.count");
        const self = try scope.createState(View, .{ .cx = cx, .scope = popup.scope, .hooks = hooks, .open = open, .root = popup.wrapper, .content = scroll.content, .chrome = popup.chrome, .painted_colors = theme.current(), .button = button, .badge = badge, .heading_count = heading_count });
        try scope.onCleanup(View, self, cleanup);
        _ = ui.clickable(button, cx.on(View, self, toggle));
        return self;
    }
    fn cleanup(self: *View) void {
        self.rows.deinit(self.cx.allocator);
    }
    fn toggle(self: *View) void {
        self.open.set(!self.open.peek());
        self.fingerprint = 0;
        self.cx.requestRedraw();
    }
    pub fn update(self: *View, entries: []const projection.Entry) !void {
        return self.updateWithCount(entries, null);
    }
    /// Historical lists may show another parent's children. The header badge
    /// continues to describe only the currently displayed main conversation.
    pub fn updateWithCount(self: *View, entries: []const projection.Entry, running_count: ?usize) !void {
        if (!std.meta.eql(self.painted_colors, theme.current())) {
            self.painted_colors = theme.current();
            self.chrome.setStyleInline(self.cx.allocator, S.popup(self.cx.tokens));
            Header.repaintCountBadge(self.cx, self.badge);
            for (self.rows.items) |row| row.repaint();
        }
        var count: usize = 0;
        var hash = std.hash.Wyhash.init(0);
        for (entries) |entry| {
            count += @intFromBool(entry.running);
            std.hash.autoHash(&hash, .{ entry.agent, entry.revision, entry.group, entry.running, entry.reusable, entry.changed_at_ms });
            hash.update(entry.name);
            hash.update(entry.status);
            hash.update(entry.summary);
        }
        count = running_count orelse count;
        var count_buffer: [64]u8 = undefined;
        const count_label = try std.fmt.bufPrint(&count_buffer, "{d} 个运行中", .{count});
        if (!sameText(self.heading_count, count_label)) try self.heading_count.setTextContent(self.cx.allocator, count_label);
        const label = try std.fmt.bufPrint(&self.a11y_label, "子智能体，{d} 个运行中", .{count});
        if (self.button.behavior.interaction.a11y) |*a11y| a11y.label = label;
        try Header.updateCountBadge(self.cx, self.badge, count);
        if (!self.open.peek()) {
            self.fingerprint = 0;
            return;
        }
        const stamp = hash.final();
        if (stamp == self.fingerprint) return;
        // While the list is open retain row nodes/order so a press cannot land
        // on a different Agent. The next open applies the latest grouped sort.
        if (self.rows.items.len != 0 and self.fingerprint != 0) {
            for (self.rows.items) |row| {
                row.node.setDisplay(.none);
                for (entries) |entry| if (row.agent.eql(entry.agent)) {
                    row.node.setDisplay(.flex);
                    try row.update(entry);
                    break;
                };
            }
            self.fingerprint = stamp;
            return;
        }
        if (self.rows_scope) |old| old.dispose();
        self.rows.clearRetainingCapacity();
        self.rows_scope = try self.scope.childScope();
        const scope = self.rows_scope.?;
        while (self.content.children.items.len != 0) {
            const node = self.content.children.items[0];
            self.cx.detachChild(self.content, node);
            self.cx.destroyDetached(node);
        }
        if (entries.len == 0) try self.content.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.secondary, "暂无子智能体"));
        var group: ?projection.Group = null;
        for (entries) |entry| {
            if (group != entry.group) {
                const header = try ui.textStyled(self.cx, S.secondary, switch (entry.group) {
                    .attention => "待处理",
                    .active => "进行中",
                    .recent => "最近结束",
                });
                header.setStyleInline(self.cx.allocator, .{ .padding = .{ .left = 52, .right = 8, .top = 8, .bottom = 4 }, .flex_shrink = 0 });
                try self.content.appendChild(self.cx.allocator, header);
                group = entry.group;
            }
            const row = try scope.createState(Row, .{ .view = self, .agent = entry.agent, .revision = entry.revision, .node = undefined, .name = undefined, .detail = undefined, .status = undefined });
            const node = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = entry.name, .base_style = ui.BoxStyle{ .width = .fill(), .height = .{ .px = 60 }, .direction = .row, .justify = .start, .align_items = .center, .padding = ui.Padding.all(10), .gap = 10, .flex_shrink = 0, .border = .{ .radius = 8 } }, .on_click = self.cx.on(Row, row, Row.select) }).mount(scope, self.cx);
            for (node.children.items) |slot| slot.setDisplay(.none);
            row.node = node;
            node.meta.ownership.meta.test_id = try std.fmt.bufPrint(&row.test_id, "ai.child.{s}", .{std.fmt.bytesToHex(entry.agent.bytes, .lower)});
            row.logo = try Logo.mount(self.cx, entry.agent);
            try node.appendChild(self.cx.allocator, row.logo);
            const copy = try ui.box(self.cx, .{ .width = .fill(), .flex = 1, .min_width = 0, .direction = .column, .gap = 3 }, .{});
            row.name = try ui.textStyled(self.cx, S.name, "");
            row.name.meta.ownership.meta.test_id = "ai.child.row.name";
            row.name.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .overflow_hidden = true });
            row.detail = try ui.textStyled(self.cx, S.secondary, "");
            row.detail.meta.ownership.meta.test_id = "ai.child.row.detail";
            row.detail.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .overflow_hidden = true });
            row.status_text = try scope.createText(entry.status, .{});
            const status_tip = try ui.widgets.Tooltip(.{ .text = row.status_text, .width = 132 }).mount(scope, self.cx);
            status_tip.wrapper.meta.ownership.meta.test_id = "ai.child.row.status";
            status_tip.wrapper.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .flex_shrink = 0 });
            status_tip.trigger.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .align_items = .center, .justify = .center, .flex_shrink = 0 });
            row.status = try ui.iconTint(self.cx, ui.icons.circle, theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
            row.status.meta.ownership.meta.test_id = "ai.child.status.icon";
            try status_tip.trigger.appendChild(self.cx.allocator, row.status);
            try copy.appendChild(self.cx.allocator, row.name);
            try copy.appendChild(self.cx.allocator, row.detail);
            try node.appendChild(self.cx.allocator, copy);
            try node.appendChild(self.cx.allocator, status_tip.wrapper);
            try self.content.appendChild(self.cx.allocator, node);
            try row.update(entry);
            try self.rows.append(self.cx.allocator, row);
        }
        self.fingerprint = stamp;
    }
    fn sameText(node: *ui.Node, value: []const u8) bool {
        return if (node.getText()) |text| std.mem.eql(u8, text.content, value) else false;
    }
    const Row = struct {
        view: *View,
        agent: id.AgentId,
        revision: u64,
        test_id: [48]u8 = undefined,
        a11y_label: [384]u8 = undefined,
        node: *ui.Node,
        logo: *ui.Node = undefined,
        status_text: *ui.Signal([]const u8) = undefined,
        visual: Visual = .complete,
        name: *ui.Node,
        detail: *ui.Node,
        status: *ui.Node,
        fn update(self: *Row, entry: projection.Entry) !void {
            self.revision = entry.revision;
            if (!View.sameText(self.name, entry.name)) try self.name.setTextContent(self.view.cx.allocator, entry.name);
            if (self.node.behavior.interaction.a11y) |*a11y| a11y.label = try std.fmt.bufPrint(&self.a11y_label, "{s}，{s}", .{ self.name.getText().?.content, entry.status });
            self.status_text.set(entry.status);
            self.visual = if (entry.running) .running else if (std.mem.eql(u8, entry.status, "失败")) .failed else if (entry.group == .attention) .attention else if (entry.group == .active) .waiting else if (std.mem.eql(u8, entry.status, "已停止")) .stopped else .complete;
            self.repaint();
            var buf: [256]u8 = undefined;
            const seconds: i64 = if (entry.changed_at_ms > 0) @max(0, @divTrunc(@import("../platform/realtime.zig").milliseconds(undefined) - entry.changed_at_ms, 1000)) else 0;
            var summary_len = @min(entry.summary.len, 100);
            while (summary_len != 0 and summary_len < entry.summary.len and entry.summary[summary_len] & 0xc0 == 0x80) summary_len -= 1;
            const detail = try std.fmt.bufPrint(&buf, "{s}{s} · {d} 秒前", .{ if (entry.summary.len != 0) entry.summary[0..summary_len] else entry.status, if (entry.reusable) " · 可复用" else "", seconds });
            if (!View.sameText(self.detail, detail)) try self.detail.setTextContent(self.view.cx.allocator, detail);
        }
        const Visual = enum { running, waiting, attention, failed, stopped, complete };
        fn repaint(self: *Row) void {
            Logo.repaint(self.logo, self.agent);
            const colors = theme.current();
            const asset = ui.icons.get(switch (self.visual) {
                .running => "loader-circle",
                .waiting => "clock-3",
                .attention => "circle-help",
                .failed => "circle-alert",
                .stopped => "circle-stop",
                .complete => "circle-check",
            }).?;
            const tint = switch (self.visual) {
                .running, .waiting => colors.accent,
                .attention => colors.warn,
                .failed => colors.danger,
                .stopped => colors.fg_2,
                .complete => colors.ok,
            };
            self.status.setIcon(.{ .icon_id = asset.icon_id.?, .rep = asset.pickRep(16).?, .tint = tint });
        }
        fn select(self: *Row) void {
            self.view.open.set(false);
            self.view.hooks.select(self.view.hooks.context, self.agent, self.revision);
        }
    };
};
