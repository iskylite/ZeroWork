//! Read-only status details, anchored to the original status card and owner.
const std = @import("std");
const ui = @import("ui");
const model = @import("status_controller.zig");
const styles = @import("status_detail_styles.zig");
const identity = @import("../host/identity.zig");

pub const Hooks = struct { context: *anyopaque, theme: ?*const fn (*anyopaque) void = null };
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    controller: model.Controller,
    hooks: Hooks,
    root: *ui.Node = undefined,
    chrome: *ui.Node = undefined,
    content: *ui.Node = undefined,
    rows: *ui.Node = undefined,
    title: *ui.Node = undefined,
    header: *ui.Node = undefined,
    header_icon: *ui.Node = undefined,
    close_button: *ui.Node = undefined,
    close_icon: *ui.Node = undefined,
    pointer: *ui.Node = undefined,
    fade: *ui.Node = undefined,
    scroll: ui.widgets.ScrollAreaResult = undefined,
    open: *ui.Signal(bool),
    row_scope: ?*ui.Scope = null,
    dirty: bool = false,
    viewport: ui.Size = .ZERO,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*View {
        const self = try cx.allocator.create(View);
        const open = try scope.createSignal(bool, false);
        self.* = .{ .cx = cx, .scope = scope, .controller = .{ .allocator = cx.allocator }, .hooks = hooks, .open = open };
        try scope.onCleanup(View, self, cleanup);
        const popup = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchor } }, .position = .top, .width = 360, .max_width = 360, .offset = .{ .static = 6 }, .viewport_padding = 8, .constrain_width_to_viewport = true, .flip = false, .shift_main_axis = false, .on_open_change = cx.on(View, self, openChanged) }).mount(scope, cx);
        self.scope = popup.scope;
        self.root = popup.wrapper;
        self.chrome = popup.chrome;
        self.content = popup.content;
        self.content.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .gap = 6 });
        self.root.setStyleInline(cx.allocator, .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 } });
        self.chrome.setStyleInline(cx.allocator, styles.panel());
        self.chrome.meta.ownership.meta.test_id = "status.detail";
        self.fade = try ui.box(cx, styles.fade(), .{});
        try self.chrome.appendChild(cx.allocator, self.fade);
        const head = try ui.box(cx, styles.header(), .{});
        self.header = head;
        self.header_icon = try ui.box(cx, styles.headerIcon(), .{});
        try head.appendChild(cx.allocator, self.header_icon);
        self.title = try ui.text(cx, "", styles.title());
        self.title.setStyleInline(cx.allocator, styles.labelBox(20));
        self.title.meta.ownership.meta.test_id = "status.detail.title";
        try head.appendChild(cx.allocator, self.title);
        try head.appendChild(cx.allocator, try ui.spacer(cx));
        const close = try ui.widgets.Button(.{ .a11y_label = "关闭状态详情", .variant = .ghost, .base_style = styles.close(false), .hover_style = styles.hover(), .on_click = cx.on(View, self, hide) }).mount(popup.scope, cx);
        self.close_button = close;
        self.close_icon = try ui.iconTint(cx, ui.icons.x, styles.theme.current().fg_2, styles.icon(14));
        try close.appendChild(cx.allocator, self.close_icon);
        close.meta.ownership.meta.test_id = "status.detail.close";
        try head.appendChild(cx.allocator, close);
        try self.content.appendChild(cx.allocator, head);
        self.scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(popup.scope, cx);
        self.rows = self.scroll.content;
        self.rows.setStyleInline(cx.allocator, styles.body());
        self.scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 });
        try self.content.appendChild(cx.allocator, self.scroll.container);
        const pointer = try ui.iconTint(cx, ui.icons.chevron_down, @import("app_theme.zig").current().fg_2, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 } });
        self.pointer = pointer;
        pointer.setStyleInline(cx.allocator, styles.pointer(174));
        try self.chrome.appendChild(cx.allocator, pointer);
        return self;
    }

    pub fn update(self: *View, projection: model.Projection) !void {
        if (try self.controller.select(projection)) self.dirty = true;
        if (self.controller.popover == null) self.open.set(false);
    }

    pub fn invalidate(self: *View, owner: identity.ContentOwner) void {
        self.controller.invalidate(owner);
        if (self.controller.popover == null) self.open.set(false);
    }

    pub fn show(self: *View, kind: model.Kind, trigger: *ui.Node, status_top: f32, narrow: bool) !void {
        const rect = trigger.globalRect();
        if (try self.controller.toggle(kind, .{ .x = rect.x, .y = status_top, .width = rect.w, .height = rect.h }, trigger.id, narrow)) |focus| {
            self.open.set(false);
            self.restoreFocus(focus);
            return;
        }
        self.dirty = true;
        self.open.set(true);
        try self.flush();
    }

    pub fn reanchor(self: *View, status_top: f32) void {
        const current = self.controller.popover orelse return;
        const trigger = find(self.cx.root orelse return, current.focus_return) orelse {
            _ = self.controller.close();
            self.open.set(false);
            return;
        };
        if (trigger.style.display == .none) {
            _ = self.controller.close();
            self.open.set(false);
            return;
        }
        const rect = trigger.globalRect();
        const next: @import("overlay_anchor.zig").Rect = .{ .x = rect.x, .y = status_top, .width = rect.w, .height = rect.h };
        if (std.meta.eql(current.anchor, next)) return;
        self.controller.updateAnchor(current.owner, next) catch return;
        self.dirty = true;
        self.chrome.markLayoutDirty();
        self.cx.requestRedraw();
    }

    pub fn flush(self: *View) !void {
        if (!std.meta.eql(self.viewport, self.cx.viewport)) {
            self.viewport = self.cx.viewport;
            self.dirty = true;
        }
        if (!self.dirty or self.controller.popover == null) return;
        self.dirty = false;
        while (self.rows.children.items.len != 0) {
            const child = self.rows.children.items[0];
            self.cx.detachChild(self.rows, child);
            self.cx.destroyDetached(child);
        }
        if (self.row_scope) |old| old.dispose();
        self.row_scope = null;
        const scope = try self.scope.childScope();
        self.row_scope = scope;
        const current = self.controller.popover.?;
        const source = self.controller.source.?.value;
        const size = try self.controller.placement(.{ .width = self.cx.viewport.width, .height = self.cx.viewport.height });
        const panel_style = styles.panel();
        self.chrome.setStyleInline(self.cx.allocator, .{ .padding = panel_style.padding, .background = panel_style.background, .border = panel_style.border, .shadow = panel_style.shadow });
        self.chrome.setStyle(self.cx.allocator, .height, .{ .px = size.height });
        self.content.setStyle(self.cx.allocator, .gap, 6);
        self.rows.setStyleInline(self.cx.allocator, styles.body());
        self.fade.setStyleInline(self.cx.allocator, styles.fade());
        self.fade.setDisplay(if (current.kind == .identity) .none else .flex);
        self.pointer.setDisplay(if (current.kind == .identity) .none else .flex);
        self.pointer.setStyleInline(self.cx.allocator, styles.pointer(@min(@max(14, current.anchor.x + current.anchor.width / 2 - size.x - 6), @max(14, size.width - 26))));
        _ = self.pointer.setTint(styles.theme.current().fg_3);
        self.close_button.setStyleInline(self.cx.allocator, styles.close(current.kind == .identity));
        self.close_icon.setStyleInline(self.cx.allocator, styles.iconBox(if (current.kind == .identity) 16 else 14));
        _ = self.close_icon.setTint(styles.theme.current().fg_2);
        var title_props = self.title.getText().?;
        const title_style = if (current.kind == .identity) styles.localTitle() else styles.title();
        title_props.font_size = title_style.font_size;
        title_props.font_weight = title_style.font_weight;
        title_props.line_height = title_style.line_height;
        title_props.color = title_style.color;
        self.title.setText(title_props);
        self.title.setStyleInline(self.cx.allocator, .{ .width = .{ .px = if (current.kind == .identity) 264 else 72 }, .height = .{ .px = if (current.kind == .identity) 18 else 20 }, .flex = 0, .flex_shrink = 0 });
        try self.title.setTextContent(self.cx.allocator, switch (current.kind) {
            .identity => "本地终端",
            .grid => "终端网格",
            .encoding => "终端编码",
            .more => "更多状态",
            .rtt => "往返延迟",
            .readonly => "只读回放",
            .theme => "全局主题",
        });
        while (self.header_icon.children.items.len != 0) {
            const child = self.header_icon.children.items[0];
            self.cx.detachChild(self.header_icon, child);
            self.cx.destroyDetached(child);
        }
        const icon = switch (current.kind) {
            .identity => ui.icons.terminal,
            .grid => ui.icons.get("move-diagonal").?,
            .encoding => ui.icons.get("type").?,
            .more => ui.icons.ellipsis,
            .rtt => ui.icons.activity,
            .readonly => ui.icons.lock,
            .theme => ui.icons.palette,
        };
        try self.header_icon.appendChild(self.cx.allocator, try ui.iconTint(self.cx, icon, @import("app_theme.zig").current().accent, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 } }));
        switch (current.kind) {
            .identity => {
                self.chrome.setStyleInline(self.cx.allocator, .{ .padding = ui.Padding.all(12) });
                self.content.setStyle(self.cx.allocator, .gap, 6);
                self.rows.setStyle(self.cx.allocator, .gap, 6);
                try self.label("本机 · macOS", 18, styles.localText(.machine));
                try self.label("/bin/zsh", 18, styles.localText(.shell));
                try self.label(source.cwd orelse "目录未知", 18, styles.localText(.cwd));
                var buffer: [96]u8 = undefined;
                const session = switch (source.owner) {
                    .session => |owner| @backingInt(owner.session_id),
                    else => 0,
                };
                var row_style = styles.row(26);
                row_style.gap = 6;
                const row = try ui.box(self.cx, row_style, .{});
                try row.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.terminal, styles.theme.current().fg_2, styles.icon(14)));
                _ = try self.rowLabel(row, try std.fmt.bufPrint(&buffer, "会话 #{d}", .{session}), styles.infoText(false), styles.labelBox(16));
                var trailing_style = styles.infoText(true);
                trailing_style.font_weight = 400;
                _ = try self.rowLabel(row, "交互式登录", trailing_style, styles.trailingBox(100));
                try self.rows.appendChild(self.cx.allocator, row);
            },
            .grid => {
                var buffer: [80]u8 = undefined;
                const value = if (source.grid) |grid| try std.fmt.bufPrint(&buffer, "{d} × {d}", .{ grid.cols, grid.rows }) else "未知";
                try self.label(value, 32, styles.value());
                try self.info(ui.icons.terminal, source.identity_label, "焦点终端");
                try self.info(ui.icons.get("move-diagonal").?, "随窗口自动调整", "PTY");
                try self.info(ui.icons.info, "列 × 行", "只读信息");
            },
            .encoding => {
                try self.info(ui.icons.check, if (source.encoding == .utf8) "UTF-8" else "编码未知", if (source.encoding == .utf8) "当前" else "未知");
                try self.info(ui.icons.get("languages").?, "Unicode 与输入法", null);
                try self.info(ui.icons.get("lock-keyhole").?, "其他编码", "暂不可用");
            },
            .more => {
                var items: [4]model.Kind = undefined;
                const available = self.controller.moreItems(&items, current.narrow_more);
                var ordered: [4]model.Kind = undefined;
                @memcpy(ordered[0..available.len], available);
                if (!current.narrow_more and available.len == 3 and ordered[2] == .rtt) ordered[0..3].* = .{ .rtt, .encoding, .grid };
                for (ordered[0..available.len]) |kind| {
                    const row = try self.cx.allocator.create(Row);
                    row.* = .{ .view = self, .owner = current.owner, .kind = kind };
                    try scope.onCleanup(Row, row, Row.cleanup);
                    const text = switch (kind) {
                        .encoding => "文本编码",
                        .grid => "终端网格",
                        .rtt => "往返延迟",
                        .theme => "全局主题",
                        else => unreachable,
                    };
                    const disabled = kind == .theme and self.hooks.theme == null;
                    const button = try ui.widgets.Button(.{ .a11y_label = text, .variant = .ghost, .base_style = styles.action(), .hover_style = styles.hover(), .disabled = disabled, .on_click = self.cx.on(Row, row, Row.click) }).mount(scope, self.cx);
                    button.meta.ownership.meta.test_id = switch (kind) {
                        .encoding => "status.more.encoding",
                        .grid => "status.more.grid",
                        .rtt => "status.more.rtt",
                        .theme => "status.more.theme",
                        else => unreachable,
                    };
                    const content = try ui.box(self.cx, styles.actionContent(), .{});
                    try button.appendChild(self.cx.allocator, content);
                    const asset = switch (kind) {
                        .encoding => ui.icons.get("type").?,
                        .grid => ui.icons.get("move-diagonal").?,
                        .rtt => ui.icons.activity,
                        .theme => ui.icons.palette,
                        else => unreachable,
                    };
                    try content.appendChild(self.cx.allocator, try ui.iconTint(self.cx, asset, styles.theme.current().fg_2, styles.icon(14)));
                    _ = try self.rowLabel(content, text, styles.infoText(false), styles.labelBox(16));
                    var buffer: [96]u8 = undefined;
                    const trailing: []const u8 = switch (kind) {
                        .encoding => if (source.encoding == .utf8) "UTF-8" else "未知",
                        .grid => if (source.grid) |grid| try std.fmt.bufPrint(&buffer, "{d}×{d}", .{ grid.cols, grid.rows }) else "未知",
                        .rtt => if (source.rtt) |sample| if (sample.milliseconds) |ms| try std.fmt.bufPrint(&buffer, "{d}ms", .{ms}) else sample.reason orelse "未知" else "暂无有效采样",
                        .theme => "应用与全部终端",
                        else => unreachable,
                    };
                    _ = try self.rowLabel(content, trailing, styles.infoText(true), styles.trailingBox(if (kind == .theme) 140 else 100));
                    try self.rows.appendChild(self.cx.allocator, button);
                }
            },
            .rtt => {
                try self.label(source.identity_label, 32, styles.title());
                var buffer: [80]u8 = undefined;
                const text = if (source.rtt) |sample| if (sample.milliseconds) |ms| try std.fmt.bufPrint(&buffer, "{d} ms", .{ms}) else sample.reason orelse "未知" else "暂无有效采样";
                try self.label(text, 26, styles.text());
            },
            .readonly => try self.label("只读回放 · 输入与执行已停用", 26, styles.text()),
            .theme => {},
        }
        self.cx.requestRedraw();
    }

    fn info(self: *View, icon: ui.SvgAsset, text: []const u8, trailing: ?[]const u8) !void {
        const row = try ui.box(self.cx, styles.infoRow(), .{});
        const tint = if (trailing != null and std.mem.eql(u8, trailing.?, "当前")) styles.theme.current().accent else styles.theme.current().fg_2;
        try row.appendChild(self.cx.allocator, try ui.iconTint(self.cx, icon, tint, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 }));
        _ = try self.rowLabel(row, text, styles.infoText(false), styles.labelBox(16));
        if (trailing) |value| {
            var style = styles.infoText(true);
            if (std.mem.eql(u8, value, "当前")) style.color = styles.theme.current().accent_ink;
            _ = try self.rowLabel(row, value, style, styles.trailingBox(100));
        }
        try self.rows.appendChild(self.cx.allocator, row);
    }

    fn label(self: *View, text: []const u8, height: f32, style: ui.TextStyle) !void {
        const row = try ui.box(self.cx, styles.row(height), .{});
        _ = try self.rowLabel(row, text, style, styles.labelBox(height));
        try self.rows.appendChild(self.cx.allocator, row);
    }
    fn rowLabel(self: *View, row: *ui.Node, text: []const u8, style: ui.TextStyle, box: ui.BoxStyle) !*ui.Node {
        const node = try ui.text(self.cx, "", style);
        node.setStyleInline(self.cx.allocator, box);
        try node.setTextContent(self.cx.allocator, text);
        try row.appendChild(self.cx.allocator, node);
        return node;
    }
    pub fn hide(self: *View) void {
        self.open.set(false);
        if (self.controller.close()) |focus| self.restoreFocus(focus);
    }
    fn restoreFocus(self: *View, token: u64) void {
        if (find(self.cx.root orelse return, token)) |node| self.cx.setFocus(node);
    }
    fn openChanged(self: *View, value: bool) void {
        if (!value) if (self.controller.close()) |focus| self.restoreFocus(focus);
    }
    fn anchor(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        const open = self.controller.popover orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return .{ .x = open.anchor.x, .y = open.anchor.y, .w = open.anchor.width, .h = 0 };
    }
    fn cleanup(self: *View) void {
        self.controller.deinit();
        self.cx.allocator.destroy(self);
    }
};

const Row = struct {
    view: *View,
    owner: identity.ContentOwner,
    kind: model.Kind,
    fn click(self: *Row) void {
        const current = self.view.controller.popover orelse return;
        if (current.kind != .more or !current.owner.eql(self.owner)) return;
        if (self.kind == .theme) {
            self.view.hide();
            if (self.view.hooks.theme) |callback| callback(self.view.hooks.context);
            return;
        }
        self.view.controller.detail(self.owner, self.kind) catch return;
        self.view.dirty = true;
        // Rebuilt at the next safe hook, never destroy this button in its click.
        self.view.cx.requestRedraw();
    }
    fn cleanup(self: *Row) void {
        self.view.cx.allocator.destroy(self);
    }
};

fn find(node: *ui.Node, token: u64) ?*ui.Node {
    if (node.id == token) return node;
    for (node.children.items) |child| if (find(child, token)) |found| return found;
    return null;
}
