//! Native presenter only. Uses one bounded body, persistent footer and live theme roles.
const std = @import("std");
const ui = @import("ui");
const S = @import("app_update_styles.zig");
pub const Action = enum { primary, cancel, release_page };
pub const Hooks = struct { context: *anyopaque, action: *const fn (*anyopaque, Action) void };
pub const Tone = enum { neutral, accent, warning, success };
pub const Row = struct { label: []const u8 = "", value: []const u8 = "", tone: Tone = .neutral };
pub const Presentation = struct {
    title: []const u8,
    description: []const u8,
    summary: []const u8 = "",
    help: []const u8 = "",
    progress: ?f32 = null,
    message: []const u8 = "",
    primary: []const u8 = "",
    cancel: []const u8 = "关闭",
    footer: []const u8 = "",
    rows: []const Row = &.{},
    enabled: bool = true,
    cancellable: bool = true,
    danger: bool = false,
    warning: bool = false,
    show_release: bool = false,
};
pub const View = struct {
    cx: *ui.Cx,
    hooks: Hooks,
    open: *ui.Signal(bool),
    disabled: *ui.Signal(bool),
    cancel_disabled: *ui.Signal(bool),
    dialog: *ui.Node,
    overlay: *ui.Node,
    body: *ui.Node,
    scroll: *ui.Node,
    actions: *ui.Node,
    content: *ui.Node,
    desired_height: f32 = 378,
    heading: *ui.Node,
    heading_icon: *ui.Node,
    description: *ui.Node,
    help: *ui.Node,
    help_icon: *ui.Node,
    help_text: *ui.Signal([]const u8),
    progress: *ui.Node,
    progress_value: *ui.Signal(f32),
    summary: *ui.Node,
    summary_text: *ui.Node,
    message: *ui.Node,
    message_paragraphs: std.ArrayList(*ui.Node) = .empty,
    footer: *ui.Node,
    row_nodes: [4]*ui.Node,
    row_labels: [4]*ui.Node,
    row_values: [4]*ui.Node,
    row_icons: [4]*ui.Node,
    row_tones: [4]Tone = @splat(.neutral),
    row_count: usize = 0,
    primary_base: *ui.Signal(ui.BoxStyle),
    cancel_base: *ui.Signal(ui.BoxStyle),
    release_base: *ui.Signal(ui.BoxStyle),
    primary_interaction: *ui.Signal(?ui.BoxStyle),
    primary_variant: *ui.Signal(ui.widgets.ButtonVariant),
    primary_text: *ui.Signal([]const u8),
    cancel_text: *ui.Signal([]const u8),
    primary: *ui.Node,
    primary_label: *ui.Node,
    cancel: *ui.Node,
    cancel_label: *ui.Node,
    release: *ui.Node,
    release_label: *ui.Node,
    close: *ui.Node,
    close_icon: *ui.Node,
    colors: S.theme.Colors,
    focus_pending: bool = false,
    danger: bool = false,
    warning: bool = false,
    primary_width: f32 = 84,
    cancel_width: f32 = 60,
    has_actions: bool = true,
    layout_height: f32 = 0,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*View {
        const self = try cx.allocator.create(View);
        errdefer cx.allocator.destroy(self);
        const open = try scope.createSignal(bool, false);
        const disabled = try scope.createSignal(bool, false);
        const cancel_disabled = try scope.createSignal(bool, false);
        const modal = try ui.widgets.Modal(.{ .open = ui.split(open, cx.on(View, self, closed)), .width = 520, .max_height = 378, .background = S.theme.current().overlay, .overlay_color = S.theme.current().app.withAlpha(92), .close_on_overlay = false }).mount(scope, cx);
        if (!modal.portaled) if (cx.root) |root| try root.appendChild(cx.allocator, modal.overlay);
        modal.dialog.setStyleInline(cx.allocator, S.dialog(cx.viewport.width, cx.viewport.height, 378));
        modal.body.setStyleInline(cx.allocator, S.body(cx.viewport.height));
        modal.dialog.meta.ownership.meta.test_id = "update.modal";
        const header = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 22 }, .direction = .row, .align_items = .center, .gap = 9, .flex_shrink = 0 }, .{});
        try modal.body.appendChild(cx.allocator, header);
        const heading_icon = try ui.iconTint(cx, ui.icons.refresh_cw, S.theme.current().accent_ink, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
        try header.appendChild(cx.allocator, heading_icon);
        const heading = try text(cx, header, "应用更新", 16, 22, 700);
        heading.meta.ownership.meta.test_id = "update.title";
        const help_text = try scope.createText("", .{});
        const help_button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "更新说明", .base_style = S.helpButton() }).mount(scope, cx);
        help_button.meta.ownership.meta.test_id = "update.help";
        const help_icon = try ui.iconTint(cx, ui.icons.circle_alert, S.theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } });
        try help_button.appendChild(cx.allocator, help_icon);
        const help = try @import("control_hint.zig").mount(cx, scope, help_button, help_text, .{ .id = "update.help.tooltip", .width = 300, .visible = open, .layout = .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .flex_shrink = 0 } });
        try header.appendChild(cx.allocator, help.wrapper);
        const close_button = try ui.widgets.Button(.{ .variant = .ghost, .disabled = cancel_disabled, .a11y_label = "关闭更新窗口", .on_click = cx.on(View, self, cancelClicked), .base_style = ui.BoxStyle{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .margin = .{ .top = -4, .right = -4, .bottom = -4 }, .padding = .ZERO, .flex_shrink = 0 } }).mount(scope, cx);
        close_button.meta.ownership.meta.test_id = "update.close";
        const close_icon = try ui.iconTint(cx, ui.icons.x, S.theme.current().fg_2, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 } });
        try close_button.appendChild(cx.allocator, close_icon);
        try header.appendChild(cx.allocator, close_button);
        const scroll = try ui.widgets.ScrollArea(.{}).mount(scope, cx);
        scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .margin = .{ .top = 14, .bottom = 18 }, .overflow = .hidden });
        try modal.body.appendChild(cx.allocator, scroll.container);
        const content = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column }, .{});
        try scroll.content.appendChild(cx.allocator, content);
        const description = try text(cx, content, "", 12, 18, 400);
        description.meta.ownership.meta.test_id = "update.detail";
        const progress_value = try scope.createSignal(f32, 0);
        const progress = try ui.widgets.Progress(.{ .value = progress_value, .height = 5, .show_text = true }).mount(scope, cx);
        progress.meta.ownership.meta.test_id = "update.download.progress";
        progress.setStyleInline(cx.allocator, S.progress());
        try content.appendChild(cx.allocator, progress);
        const summary = try ui.box(cx, S.summary(cx.viewport.height), .{});
        summary.meta.ownership.meta.test_id = "update.summary";
        try content.appendChild(cx.allocator, summary);
        const summary_text = try text(cx, summary, "", 12, 20, 400);
        var row_nodes: [4]*ui.Node = undefined;
        var row_labels: [4]*ui.Node = undefined;
        var row_values: [4]*ui.Node = undefined;
        var row_icons: [4]*ui.Node = undefined;
        for ([_]ui.SvgAsset{ ui.icons.terminal, ui.icons.arrow_down_up, ui.icons.sparkles, ui.icons.network }, 0..) |asset, i| {
            const row = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 34 }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 }, .{});
            try summary.appendChild(cx.allocator, row);
            row_nodes[i] = row;
            const icon = try ui.iconTint(cx, asset, S.theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
            try row.appendChild(cx.allocator, icon);
            row_icons[i] = icon;
            row_labels[i] = try text(cx, row, "", 12, 18, 400);
            row_values[i] = try ui.text(cx, "", .{ .font_size = 11, .line_height = 18.0 / 11.0, .color = S.theme.current().fg_2, .text_align = .end });
            try row.appendChild(cx.allocator, row_values[i]);
            row_values[i].setStyleInline(cx.allocator, .{ .width = .{ .px = 108 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
        }
        const message = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .margin = .{ .bottom = 6 }, .flex_shrink = 0 }, .{});
        try content.appendChild(cx.allocator, message);
        message.meta.ownership.meta.test_id = "update.message";
        message.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
        const actions = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .gap = 8, .align_items = .center, .flex_shrink = 0 }, .{});
        try modal.body.appendChild(cx.allocator, actions);
        const footer = try text(cx, actions, "", 11, 17, 400);
        footer.meta.ownership.meta.test_id = "update.progress";
        const release_base = try scope.createSignal(ui.BoxStyle, S.button(false, false, 72));
        const cancel_base = try scope.createSignal(ui.BoxStyle, S.button(false, false, 60));
        const primary_base = try scope.createSignal(ui.BoxStyle, S.button(true, false, 100));
        const primary_interaction = try scope.createSignal(?ui.BoxStyle, S.button(true, false, 100));
        const primary_variant = try scope.createSignal(ui.widgets.ButtonVariant, .primary);
        const primary_text = try scope.createText("检查更新", .{});
        const cancel_text = try scope.createText("关闭", .{});
        const release = try ui.widgets.Button(.{ .label = "发布页", .variant = .ghost, .on_click = cx.on(View, self, releaseClicked), .a11y_label = "打开官方发布页", .base_style = release_base }).mount(scope, cx);
        release.meta.ownership.meta.test_id = "update.release";
        const release_label = firstText(release).?;
        try actions.appendChild(cx.allocator, release);
        const cancel = try ui.widgets.Button(.{ .label = cancel_text, .variant = .secondary, .disabled = cancel_disabled, .on_click = cx.on(View, self, cancelClicked), .base_style = cancel_base }).mount(scope, cx);
        cancel.meta.ownership.meta.test_id = "update.cancel";
        const cancel_label = firstText(cancel).?;
        try actions.appendChild(cx.allocator, cancel);
        const primary = try ui.widgets.Button(.{ .label = primary_text, .variant = primary_variant, .disabled = disabled, .on_click = cx.on(View, self, primaryClicked), .base_style = primary_base, .hover_style = primary_interaction, .pressed_style = primary_interaction }).mount(scope, cx);
        primary.meta.ownership.meta.test_id = "update.primary";
        const primary_label = firstText(primary).?;
        try actions.appendChild(cx.allocator, primary);
        self.* = .{ .cx = cx, .hooks = hooks, .open = open, .disabled = disabled, .cancel_disabled = cancel_disabled, .dialog = modal.dialog, .overlay = modal.overlay, .body = modal.body, .scroll = scroll.container, .actions = actions, .content = content, .heading = heading, .heading_icon = heading_icon, .description = description, .help = help.wrapper, .help_icon = help_icon, .help_text = help_text, .progress = progress, .progress_value = progress_value, .summary = summary, .summary_text = summary_text, .message = message, .footer = footer, .row_nodes = row_nodes, .row_labels = row_labels, .row_values = row_values, .row_icons = row_icons, .primary_interaction = primary_interaction, .primary_base = primary_base, .cancel_base = cancel_base, .release_base = release_base, .primary_variant = primary_variant, .primary_text = primary_text, .cancel_text = cancel_text, .primary = primary, .primary_label = primary_label, .cancel = cancel, .cancel_label = cancel_label, .release = release, .release_label = release_label, .close = close_button, .close_icon = close_icon, .colors = S.theme.current() };
        try scope.onCleanup(View, self, cleanup);
        try cx.addAfterLayoutHook(self, frame);
        self.retheme();
        return self;
    }
    pub fn show(self: *View) void {
        self.open.set(true);
        self.focus_pending = true;
        self.cx.requestRedraw();
    }
    pub fn hide(self: *View) void {
        self.open.set(false);
        self.cx.requestRedraw();
    }
    pub fn update(self: *View, p: Presentation) !void {
        try self.heading.setTextContent(self.cx.allocator, p.title);
        try self.description.setTextContent(self.cx.allocator, p.description);
        try self.summary_text.setTextContent(self.cx.allocator, p.summary);
        self.help_text.set(p.help);
        self.help.setDisplay(if (p.help.len == 0) .none else .flex);
        self.progress_value.set(p.progress orelse 0);
        self.progress.setDisplay(if (p.progress == null) .none else .flex);
        try self.setMessage(p.message);
        try self.footer.setTextContent(self.cx.allocator, p.footer);
        self.primary_text.set(if (p.primary.len == 0) "检查更新" else p.primary);
        self.cancel_text.set(if (p.cancel.len == 0) "关闭" else p.cancel);
        self.description.setDisplay(if (p.description.len == 0) .none else .flex);
        self.message.setDisplay(if (p.message.len == 0) .none else .flex);
        self.summary_text.setDisplay(if (p.summary.len == 0) .none else .flex);
        self.summary.setDisplay(if (p.summary.len == 0 and p.rows.len == 0) .none else .flex);
        self.description.setStyleInline(self.cx.allocator, .{ .margin = .{ .bottom = if (p.summary.len == 0 and p.rows.len == 0) 6 else 0 } });
        self.row_count = @min(4, p.rows.len);
        for (0..4) |i| {
            self.row_nodes[i].setDisplay(if (i < self.row_count) .flex else .none);
            if (i < self.row_count) {
                try self.row_labels[i].setTextContent(self.cx.allocator, p.rows[i].label);
                try self.row_values[i].setTextContent(self.cx.allocator, p.rows[i].value);
                self.row_tones[i] = p.rows[i].tone;
                const asset = rowIcon(p.rows[i].label);
                if (asset.icon_id) |id| if (asset.pickRep(16)) |rep| self.row_icons[i].setIcon(.{ .icon_id = id, .rep = rep, .tint = S.theme.current().fg_2 });
            }
        }
        self.danger = p.danger;
        self.warning = p.warning;
        self.disabled.set(!p.enabled);
        self.cancel_disabled.set(!p.cancellable);
        self.primary.setDisplay(if (p.primary.len == 0) .none else .flex);
        self.cancel.setDisplay(if (p.cancel.len == 0) .none else .flex);
        self.release.setDisplay(if (p.show_release) .flex else .none);
        self.has_actions = p.primary.len != 0 or p.cancel.len != 0 or p.show_release or p.footer.len != 0;
        self.actions.setDisplay(if (self.has_actions) .flex else .none);
        self.close.setStyleInline(self.cx.allocator, .{ .opacity = if (p.cancellable) 1 else 0 });
        // Match intrinsic label width. Fixed 84px clipped the longest destructive action.
        self.primary_width = @max(72, self.cx.text.measureTextWidth(p.primary, 12, 500, false) + 24);
        self.cancel_width = @max(48, self.cx.text.measureTextWidth(p.cancel, 12, 500, false) + 24);
        self.retheme();
        self.cx.requestRedraw();
    }
    fn setMessage(self: *View, value: []const u8) !void {
        var paragraphs = std.mem.splitScalar(u8, value, '\n');
        var count: usize = 0;
        while (paragraphs.next()) |paragraph| {
            if (count == self.message_paragraphs.items.len) {
                try self.message_paragraphs.ensureUnusedCapacity(self.cx.allocator, 1);
                self.message_paragraphs.appendAssumeCapacity(try text(self.cx, self.message, "", 11, 17, 400));
            }
            const node = self.message_paragraphs.items[count];
            try node.setTextContent(self.cx.allocator, paragraph);
            node.setDisplay(.flex);
            count += 1;
        }
        for (self.message_paragraphs.items[count..]) |node| node.setDisplay(.none);
    }
    fn rowIcon(label: []const u8) ui.SvgAsset {
        if (std.mem.eql(u8, label, "文件传输")) return ui.icons.arrow_down_up;
        if (std.mem.startsWith(u8, label, "AI")) return ui.icons.sparkles;
        if (std.mem.startsWith(u8, label, "KVM")) return ui.icons.network;
        return ui.icons.terminal;
    }
    fn firstText(node: *ui.Node) ?*ui.Node {
        if (node.getText() != null) return node;
        for (node.children.items) |child| if (firstText(child)) |found| return found;
        return null;
    }
    fn text(cx: *ui.Cx, parent: *ui.Node, value: []const u8, size: f32, line: f32, weight: u16) !*ui.Node {
        const node = try ui.text(cx, value, S.text(size, line, weight));
        node.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .flex_shrink = 0 });
        try parent.appendChild(cx.allocator, node);
        return node;
    }
    fn primaryClicked(self: *View) void {
        self.hooks.action(self.hooks.context, .primary);
    }
    fn cancelClicked(self: *View) void {
        self.hooks.action(self.hooks.context, .cancel);
    }
    fn releaseClicked(self: *View) void {
        self.hooks.action(self.hooks.context, .release_page);
    }
    fn closed(self: *View, value: bool) void {
        if (!value) self.hooks.action(self.hooks.context, .cancel);
    }
    fn retheme(self: *View) void {
        const c = S.theme.current();
        const m = S.metrics(self.cx.viewport.height);
        self.dialog.setStyleInline(self.cx.allocator, S.dialog(self.cx.viewport.width, self.cx.viewport.height, self.desired_height));
        self.body.setStyleInline(self.cx.allocator, S.body(self.cx.viewport.height));
        self.scroll.setStyleInline(self.cx.allocator, .{ .margin = .{ .top = m.body_top, .bottom = if (self.has_actions) m.footer_gap else 0 } });
        self.summary.setStyleInline(self.cx.allocator, S.summary(self.cx.viewport.height));
        self.overlay.setBackground(c.app.withAlpha(92));
        self.heading.setTextColor(c.fg_1);
        self.description.setTextColor(c.fg_1);
        self.summary_text.setTextColor(c.fg_1);
        for (self.message_paragraphs.items) |node| node.setTextColor(if (self.warning) c.warn_ink else c.fg_2);
        self.footer.setTextColor(c.fg_2);
        self.cancel_label.setTextColor(c.fg_1);
        self.release_label.setTextColor(c.accent_ink);
        self.primary_label.setTextColor(ui.Color.WHITE);
        const asset = if (self.warning or self.danger) ui.icons.triangle_alert else ui.icons.refresh_cw;
        if (asset.icon_id) |id| if (asset.pickRep(18)) |rep| self.heading_icon.setIcon(.{ .icon_id = id, .rep = rep, .tint = if (self.warning or self.danger) c.warn_ink else c.accent_ink });
        _ = self.close_icon.setTint(c.fg_2);
        _ = self.help_icon.setTint(c.fg_2);
        for (0..4) |i| {
            self.row_nodes[i].setStyleInline(self.cx.allocator, .{ .height = .{ .px = m.row_height } });
            self.row_labels[i].setTextColor(c.fg_1);
            if (i < self.row_count) {
                // Counts can grow beyond one digit. Keep the approved 108px
                // minimum, then use actual text width while reserving the
                // category label, its 16px icon and both existing 8px gaps.
                const row_width = S.dialog(self.cx.viewport.width, self.cx.viewport.height, self.desired_height).width.?.px - 2 * m.padding - 2 * m.summary_padding;
                const label_width = self.cx.text.measureTextWidth(self.row_labels[i].getText().?.content, 12, 400, false);
                const value_width = @ceil(self.cx.text.measureTextWidth(self.row_values[i].getText().?.content, 11, 400, false));
                const max_width = @max(108, row_width - label_width - 16 - 8 - 8);
                self.row_values[i].setStyleInline(self.cx.allocator, .{ .width = .{ .px = @min(max_width, @max(108, value_width)) } });
            }
            self.row_values[i].setTextColor(switch (self.row_tones[i]) {
                .neutral => c.fg_2,
                .accent => c.accent_ink,
                .warning => c.warn_ink,
                .success => c.ok_ink,
            });
            _ = self.row_icons[i].setTint(c.fg_2);
        }
        self.primary_variant.set(if (self.danger) .danger else .primary);
        self.primary_base.set(S.button(true, self.danger, self.primary_width));
        self.primary_interaction.set(S.button(true, self.danger, self.primary_width));
        // Match the app's primary paint path. The retained Button recipe owns
        // its animated background; explicit paint keeps the approved action
        // role visible across theme/hover transitions, without changing tokens.
        self.primary.setStyle(self.cx.allocator, .gradient, if (self.disabled.peek()) null else if (self.danger) .{ .from = c.action_danger, .to = c.action_danger, .direction = .diagonal } else @import("shell_styles.zig").emptyButton(true).gradient);

        self.cancel_base.set(S.button(false, false, self.cancel_width));
        self.release_base.set(S.button(false, false, 72));
        self.colors = c;
        self.layout_height = self.cx.viewport.height;
    }
    fn frame(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.open.peek()) return .done;
        const m = S.metrics(self.cx.viewport.height);
        const height = self.content.globalRect().h + 2 * m.padding + 22 + m.body_top + (if (self.has_actions) m.footer_gap + 32 else @as(f32, 0));
        if (@abs(height - self.desired_height) > 0.5) {
            self.desired_height = height;
            self.retheme();
            return .needs_layout;
        }
        const s = S.dialog(self.cx.viewport.width, self.cx.viewport.height, self.desired_height);
        if (!std.meta.eql(self.colors, S.theme.current()) or self.layout_height != self.cx.viewport.height or @abs(self.dialog.globalRect().w - s.width.?.px) > 0.5 or @abs(self.dialog.globalRect().h - s.height.?.px) > 0.5) {
            self.retheme();
            return .needs_layout;
        }
        if (self.focus_pending) {
            self.focus_pending = false;
            self.cx.setFocus(self.cancel);
        }
        return .done;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        self.message_paragraphs.deinit(self.cx.allocator);
        self.cx.allocator.destroy(self);
    }
};
