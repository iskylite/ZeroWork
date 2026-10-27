//! Read-only frozen event snapshot. No Manager/engine mutation or current-owner lookup.
const std = @import("std");
const ui = @import("ui");
const S = @import("transfer_events_styles.zig");
const theme = @import("app_theme.zig");
pub const View = struct {
    cx: *ui.Cx,
    open: *ui.Signal(bool),
    dialog: *ui.Node = undefined,
    title: *ui.Node = undefined,
    entries: *ui.Node = undefined,
    snapshot: []const u8 = "",
    colors: theme.Colors = undefined,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .open = try scope.createSignal(bool, false), .colors = theme.current() });
        try scope.onCleanup(View, self, cleanup);
        const modal = try ui.widgets.Modal(.{ .open = self.open, .width = 520, .max_height = 242, .background = theme.current().overlay, .overlay_color = ui.Color.TRANSPARENT, .close_on_overlay = false, .on_open_change = cx.on(View, self, changed) }).mount(scope, cx);
        if (!modal.portaled) try cx.root.?.appendChild(cx.allocator, modal.overlay);
        self.dialog = modal.dialog;
        self.dialog.setStyleInline(cx.allocator, S.dialog(cx.tokens));
        try self.dialog.insertChildBefore(cx.allocator, try ui.boxStyled(cx, @import("transfer_styles.zig").topFade, .{}), modal.body);
        try self.dialog.appendChild(cx.allocator, try ui.boxStyled(cx, @import("transfer_styles.zig").grip, .{}));
        self.dialog.meta.ownership.meta.test_id = "transfer.events.dialog";
        modal.body.setStyleInline(cx.allocator, S.body(cx.tokens));
        const head = try ui.boxStyled(cx, S.row, .{});
        try head.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("file-clock").?, theme.current().accent, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 } }));
        self.title = try ui.textStyled(cx, S.title, "任务事件");
        try head.appendChild(cx.allocator, self.title);
        try head.appendChild(cx.allocator, try ui.spacer(cx));
        const x = try ui.widgets.Button(.{ .icon_asset = ui.icons.x, .icon_only = true, .a11y_label = "关闭任务事件", .variant = .ghost, .on_click = cx.on(View, self, close), .base_style = S.button(22) }).mount(scope, cx);
        x.meta.ownership.meta.test_id = "transfer.events.dismiss";
        try head.appendChild(cx.allocator, x);
        try modal.body.appendChild(cx.allocator, head);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        scroll.container.setStyleInline(cx.allocator, S.viewport(cx.tokens));
        scroll.container.meta.ownership.meta.test_id = "transfer.events.viewport";
        self.entries = try ui.boxStyled(cx, S.eventList, .{});
        self.entries.meta.ownership.meta.test_id = "transfer.events.entries";
        try scroll.content.appendChild(cx.allocator, self.entries);
        try modal.body.appendChild(cx.allocator, scroll.container);
        try @import("compact_overlay_layout.zig").mount(cx, scope, self.dialog, scroll.container, scroll.content, 58, 184, null, 0);
        return self;
    }
    pub fn show(self: *View, job: u64, entries: []const u8) !void {
        var buffer: [80]u8 = undefined;
        try self.title.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "任务事件 · #{d}", .{job}));
        const snapshot = try self.cx.allocator.dupe(u8, entries);
        while (self.entries.children.items.len > 0) {
            const child = self.entries.children.items[0];
            self.entries.removeChild(child);
            self.cx.destroyDetached(child);
        }
        self.cx.allocator.free(self.snapshot);
        self.snapshot = snapshot;
        var lines = std.mem.splitScalar(u8, if (snapshot.len == 0) "暂无任务事件" else snapshot, '\n');
        while (lines.next()) |line| {
            const row = try ui.boxStyled(self.cx, S.eventRow, .{});
            try self.entries.appendChild(self.cx.allocator, row);
            const entry = try ui.textStyled(self.cx, S.entries, line);
            entry.setStyleInline(self.cx.allocator, .{ .width = .fill(), .flex_shrink = 0 });
            entry.meta.ownership.meta.test_id = "transfer.events.entry";
            try row.appendChild(self.cx.allocator, entry);
            try @import("log_typography.zig").apply(self.cx, entry);
        }
        self.dialog.setStyleInline(self.cx.allocator, S.dialog(self.cx.tokens));
        self.open.set(true);
    }
    pub fn retheme(self: *View) void {
        @import("transfer_styles.zig").repaint(self.dialog, self.colors);
        self.colors = theme.current();
        self.dialog.setStyleInline(self.cx.allocator, S.dialog(self.cx.tokens));
    }
    pub fn close(self: *View) void {
        self.open.set(false);
    }
    fn changed(self: *View, open: bool) void {
        self.open.set(open);
    }
    fn cleanup(self: *View) void {
        self.cx.allocator.free(self.snapshot);
    }
};
