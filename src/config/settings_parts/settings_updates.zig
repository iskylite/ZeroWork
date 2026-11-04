//! Native composition of the approved editable V3 About/update page.
const std = @import("std");
const ui = @import("ui");
const binding = @import("../settings_content_view.zig");
const controls = @import("settings_controls.zig");
const S = @import("settings_updates_styles.zig");
const theme = S.theme;

const Click = struct {
    bound: *binding.Binding,
    action: binding.Action = .check_updates,
    fn run(self: *@This()) void {
        if (self.bound.saving.peek()) return;
        self.bound.hooks.action(self.bound.hooks.context, self.action);
    }
};
fn read(bound: *binding.Binding, key: []const u8, fallback: []const u8) []const u8 {
    if (bound.hooks.read) |get| if (get(bound.hooks.context, .{ .section = "updates", .key = key })) |value| return value.text;
    return fallback;
}
fn ink(cx: *ui.Cx, parent: *ui.Node, value: []const u8, size: f32, height: f32, weight: u16, comptime role: []const u8) !*ui.Node {
    const node = try ui.text(cx, value, .{ .font_size = size, .line_height = height / size, .font_weight = weight, .color = @field(theme.current(), role), .wrap = .word });
    node.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .flex_shrink = 0 });
    theme.bindInk(node, role);
    try parent.appendChild(cx.allocator, node);
    return node;
}

/// Read runtime metadata into retained text/control nodes. Updating a check never
/// replaces the preference field, its draft, or the user's current focus.
const Live = struct {
    cx: *ui.Cx,
    bound: *binding.Binding,
    version: ?*ui.Node = null,
    badge: ?*ui.Node = null,
    title: ?*ui.Node = null,
    last_check: ?*ui.Node = null,
    channel: ?*ui.Node = null,
    action_label: *ui.Signal([]const u8),
    disabled: *ui.Signal(bool),
    section: ?*controls.Section = null,

    fn cleanup(self: *@This()) void {
        self.cx.removeAfterLayoutHook(self);
        self.bound.scope.allocator.destroy(self);
    }
    fn text(self: *@This(), node: ?*ui.Node, value: []const u8) bool {
        const target = node orelse return false;
        if (target.getText()) |old| if (std.mem.eql(u8, old.content, value)) return false;
        target.setTextContent(self.cx.allocator, value) catch return false;
        return true;
    }
    fn refresh(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *@This() = @ptrCast(@alignCast(raw));
        var changed = false;
        var version_buffer: [1024]u8 = undefined;
        const version = std.fmt.bufPrint(&version_buffer, "{s} · {s}", .{ read(self.bound, "current_version", "—"), read(self.bound, "version_metadata", "构建信息未知") }) catch "版本信息未知";
        changed = self.text(self.version, version) or changed;
        changed = self.text(self.badge, read(self.bound, "version_badge", "待检查")) or changed;
        changed = self.text(self.title, read(self.bound, "available_title", "检查是否有可用的新版本")) or changed;
        changed = self.text(self.last_check, read(self.bound, "last_check", "尚未检查")) or changed;
        changed = self.text(self.channel, read(self.bound, "release_channel", "正式版")) or changed;
        const state = read(self.bound, "state", "");
        const checking = std.mem.eql(u8, state, "checking");
        const label: []const u8 = if (std.mem.eql(u8, state, "draining")) "查看收尾进度" else if (checking) "正在检查…" else if (read(self.bound, "available_version", "").len != 0) "查看更新" else "检查更新";
        if (!std.mem.eql(u8, self.action_label.peek(), label)) {
            self.action_label.set(label);
            changed = true;
        }
        const disabled = self.bound.saving.peek() or checking;
        if (self.disabled.peek() != disabled) self.disabled.set(disabled);
        if (self.section) |section| {
            // Reuse Section + its Config-backed Switch. This particular reference
            // is an always-open card, with a plain title rather than a fold row.
            if (section.root.style.padding.left != 16 or section.header.style.min_height() != 20) {
                section.root.setStyleInline(self.cx.allocator, S.card(undefined));
                section.header.setStyleInline(self.cx.allocator, S.preferenceHeader(undefined));
                section.body.setStyleInline(self.cx.allocator, S.preferenceBody(undefined));
                changed = true;
            }
            section.header.setFocusable(false);
        }
        return if (changed) .needs_layout else .done;
    }
};

pub fn mountContent(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const page = try controls.Page.create(cx, bound, "settings.updates");
    const live = try bound.scope.allocator.create(Live);
    live.* = .{ .cx = cx, .bound = bound, .action_label = try bound.scope.createText("检查更新", .{}), .disabled = try bound.scope.createSignal(bool, bound.saving.peek()) };
    try bound.scope.onCleanup(Live, live, Live.cleanup);
    try cx.addAfterLayoutHook(live, Live.refresh);
    try bound.scope.createEffect(.{ .live = live }, struct {
        fn run(ctx: anytype) void {
            const saving = ctx.live.bound.saving.get();
            ctx.live.disabled.set(saving or std.mem.eql(u8, read(ctx.live.bound, "state", ""), "checking"));
        }
    }.run);
    const click = try bound.scope.createState(Click, .{ .bound = bound });
    if (binding.matches(bound.controller.search_query, "ZeroWork 关于 更新 版本 检查 update version")) {
        const card = try ui.boxStyled(cx, S.card, .{});
        card.meta.ownership.meta.test_id = "settings.updates.version";
        try page.root.appendChild(cx.allocator, card);
        try theme.bindMaterial(cx, bound.scope, card, "surface_2");
        const identity = try ui.boxStyled(cx, S.identity, .{});
        try card.appendChild(cx.allocator, identity);
        const mark = try ui.boxStyled(cx, S.appMark, .{});
        try identity.appendChild(cx.allocator, mark);
        try mark.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.terminal, theme.actionForeground(theme.current().action_accent), .{ .width = .{ .px = 24 }, .height = .{ .px = 24 } }));
        const title = try ui.boxStyled(cx, S.column, .{});
        title.setStyleInline(cx.allocator, .{ .gap = 3, .flex = 1 });
        try identity.appendChild(cx.allocator, title);
        _ = try ink(cx, title, "ZeroWork", 17, 24, 650, "fg_1");
        live.version = try ink(cx, title, "", 11, 18, 400, "fg_2");
        live.version.?.meta.ownership.meta.test_id = "settings.updates.version_text";
        const badge = try ui.boxStyled(cx, S.badge, .{});
        badge.meta.ownership.meta.test_id = "settings.updates.badge";
        try identity.appendChild(cx.allocator, badge);
        live.badge = try ink(cx, badge, "待检查", 11, 18, 600, "accent_ink");
        live.badge.?.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} } });
        try card.appendChild(cx.allocator, try ui.boxStyled(cx, S.divider, .{}));
        const detail = try ui.boxStyled(cx, S.detail, .{});
        try card.appendChild(cx.allocator, detail);
        const labels = try ui.boxStyled(cx, S.column, .{});
        labels.setStyleInline(cx.allocator, .{ .gap = 4, .flex = 1 });
        try detail.appendChild(cx.allocator, labels);
        live.title = try ink(cx, labels, "检查是否有可用的新版本", 13, 20, 650, "fg_1");
        _ = try ink(cx, labels, "Apple Silicon · macOS 13 或更新版本", 11, 18, 400, "fg_2");
        const primary_style = try theme.paintSignal(controls.S.ButtonStyle, cx, bound.scope, S.primaryButton, .{});
        const button = try ui.widgets.Button(.{ .label = live.action_label, .variant = .primary, .disabled = live.disabled, .on_click = cx.on(Click, click, Click.run), .base_style = primary_style }).mount(bound.scope, cx);
        button.meta.ownership.meta.test_id = "settings.updates.open";
        try theme.stylePrimary(cx, bound.scope, button, live.disabled);
        try detail.appendChild(cx.allocator, button);
        const footer = try ui.boxStyled(cx, S.versionFooter, .{});
        try card.appendChild(cx.allocator, footer);
        const note = try ink(cx, footer, "下载与安装由你确认", 11, 18, 400, "fg_2");
        note.setStyleInline(cx.allocator, .{ .flex = 1 });
        const text_style = try theme.paintSignal(controls.S.ButtonStyle, cx, bound.scope, S.textButton, .{});
        const check = try ui.widgets.Button(.{ .label = "检查更新", .variant = .link, .disabled = live.disabled, .on_click = cx.on(Click, click, Click.run), .base_style = text_style }).mount(bound.scope, cx);
        check.meta.ownership.meta.test_id = "settings.updates.check";
        try footer.appendChild(cx.allocator, check);
    }
    if (binding.matches(bound.controller.search_query, "自动 检查 更新 偏好 通道 正式版 auto_check channel")) {
        const section = try page.section("更新偏好", "", ui.icons.refresh_cw, 59, "settings.updates.preferences", null);
        live.section = section;
        section.expanded.set(true);
        section.header.behavior.events.on_event = null;
        section.header.behavior.events.on_click = null;
        section.header.setCursor(.default);
        if (section.header.behavior.interaction.a11y) |*a11y| {
            a11y.role = .heading;
            a11y.expanded = null;
            a11y.expansion = null;
        }
        section.header.children.items[1].children.items[0].behavior.events.on_event = null;
        // Keep the shared title/field composition, omitting decorations absent
        // from the approved card. No hidden folding action remains keyboardable.
        section.header.children.items[0].setDisplay(.none);
        section.header.children.items[section.header.children.items.len - 1].setDisplay(.none);
        try section.toggle(.{ .section = "updates", .key = "auto_check" }, "自动检查更新", "", null);
        if (section.body.children.items.len != 0) {
            const field_root = section.body.children.items[0];
            const field_row = field_root.children.items[0];
            field_row.setStyleInline(cx.allocator, S.preferenceRow(undefined));
            const labels = field_row.children.items[0];
            _ = try ink(cx, labels, "启动后检查，自动检查按 24 小时限频", 11, 16, 400, "fg_2");
            const label = labels.children.items[0].children.items[0];
            if (label.getText()) |old| {
                var text = old;
                text.font_weight = 400;
                label.setText(text);
            }
        }
        const channel = try ui.boxStyled(cx, S.preferenceRow, .{});
        channel.meta.ownership.meta.test_id = "settings.updates.channel";
        try section.body.appendChild(cx.allocator, channel);
        const channel_label = try ink(cx, channel, "更新通道", 12, 18, 400, "fg_1");
        channel_label.setStyleInline(cx.allocator, .{ .flex = 1 });
        live.channel = try ink(cx, channel, "正式版", 12, 18, 400, "fg_2");
        live.channel.?.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .flex_shrink = 0 });
    }
    if (binding.matches(bound.controller.search_query, "检查 来源 GitHub release update")) {
        const notes = try ui.boxStyled(cx, S.notes, .{});
        try page.root.appendChild(cx.allocator, notes);
        live.last_check = try ink(cx, notes, "尚未检查", 11, 18, 400, "fg_2");
        live.last_check.?.meta.ownership.meta.test_id = "settings.updates.last_check";
        const release = try bound.scope.createState(Click, .{ .bound = bound, .action = .open_update_release });
        const style = try theme.paintSignal(controls.S.ButtonStyle, cx, bound.scope, S.sourceButton, .{});
        const source = try ui.widgets.Button(.{ .label = "发布来源：GitHub / iskylite / ZeroWork", .variant = .link, .disabled = bound.saving, .on_click = cx.on(Click, release, Click.run), .base_style = style }).mount(bound.scope, cx);
        source.meta.ownership.meta.test_id = "settings.updates.source";
        try source.appendChild(cx.allocator, try theme.icon(cx, ui.icons.external_link, "accent_ink", .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 }));
        try notes.appendChild(cx.allocator, source);
    }
    return page.finish();
}
