//! Live settings controls sharing one owned draft and fixed save footer.
const std = @import("std");
const ui = @import("ui");
const config = @import("config.zig");
const Controller = @import("settings_controller.zig").Controller;
const values = @import("settings_values.zig");
const schema = @import("settings_schema.zig");
const design = @import("../ui/design_tokens.zig");
pub const styles = @import("settings_styles.zig");
pub const Action = enum { reset_defaults, revert, save, import_theme, export_logs, clear_logs, clear_all, open_config_dir, credential_help };
pub const ActionState = struct { enabled: bool = true, reason: ?[]const u8 = null };
pub const Key = struct { section: []const u8, key: []const u8 };
pub const Hooks = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    request_edit: *const fn (*anyopaque, Key, *ui.Node) void,
    action: *const fn (*anyopaque, Action) void,
    action_state: ?*const fn (*anyopaque, Action) ActionState = null,
    read: ?*const fn (*anyopaque, Key) ?values.Value = null,
    edit: ?*const fn (*anyopaque, Key, values.Value) void = null,
    keybindings: ?*const @import("keybindings.zig").Map = null,
    shortcut_text: ?*const fn (*anyopaque, []const u8, []u8) anyerror![]const u8 = null,
    mount_providers: ?*const fn (*anyopaque, *ui.Cx, *ui.Scope) anyerror!*ui.Node = null,
    mount_provider_action: ?*const fn (*anyopaque, *ui.Cx, *ui.Scope) anyerror!*ui.Node = null,
    appearance: ?*@import("appearance_ui_context.zig").Context = null,
    authorization_help: ?*const fn (*anyopaque) []const u8 = null,
    authorization_feedback: ?*const fn (*anyopaque) ?[]const u8 = null,
};
const Row = struct { label: []const u8, section: []const u8, key: []const u8 };
pub const modal_heights: [8]f32 = @splat(styles.geometry.panel_height);

/// Keep a settings card inside the usable viewport.  The 32px inset is the
/// same boundary used by the host when constraining the modal during resize.
/// Clamping the lower bound is important for very small windows: a negative
/// (or zero) height would make the scroll viewport and its footer unreachable.
pub fn constrainedModalHeight(page_index: usize, viewport_height: f32) f32 {
    _ = page_index;
    const available = viewport_height - 2 * @import("../ui/v3_geometry.zig").settings_inset;
    const target = if (viewport_height <= 480) styles.geometry.compact_height else styles.geometry.panel_height;
    return @max(@as(f32, 1), @min(target, available));
}

test "settings modal height never becomes negative in a tiny viewport" {
    try std.testing.expectEqual(@as(f32, 1), constrainedModalHeight(0, 16));
    try std.testing.expectEqual(@as(f32, 1), constrainedModalHeight(0, 32));
    try std.testing.expectEqual(@as(f32, 68), constrainedModalHeight(0, 100));
    try std.testing.expectEqual(@as(f32, 640), constrainedModalHeight(0, 900));
    try std.testing.expectEqual(@as(f32, 640), constrainedModalHeight(999, 900));
    try std.testing.expectEqual(@as(f32, 432), constrainedModalHeight(0, 480));
}

pub const rows = [_]Row{
    .{ .label = "字体族", .section = "ui", .key = "font_family" },
    .{ .label = "字体大小", .section = "ui", .key = "font_size" },
    .{ .label = "行间距", .section = "ui", .key = "line_height" },
    .{ .label = "光标样式", .section = "ui", .key = "cursor_style" },
    .{ .label = "时间戳侧栏", .section = "ui", .key = "timestamp_gutter" },
    .{ .label = "App 级命令补全", .section = "completion", .key = "enabled" },
    .{ .label = "输入行相对高亮", .section = "ui", .key = "input_line_highlight" },
    .{ .label = "KeepAlive 间隔", .section = "ssh", .key = "keepalive_sec" },
    .{ .label = "连接超时", .section = "ssh", .key = "connect_timeout_sec" },
    .{ .label = "默认终端类型", .section = "ssh", .key = "term" },
    .{ .label = "SSH 压缩 (zlib)", .section = "ssh", .key = "compression" },
    .{ .label = "自动重连", .section = "ssh", .key = "auto_reconnect" },
    .{ .label = "最大重连次数", .section = "ssh", .key = "reconnect_max" },
    .{ .label = "退避序列", .section = "ssh", .key = "reconnect_backoff" },
    .{ .label = "重连期间输入缓存", .section = "ssh", .key = "buffer_input" },
    .{ .label = "默认本地端口", .section = "ssh", .key = "socks_port" },
    .{ .label = "默认绑定地址", .section = "ssh", .key = "socks_bind" },
    .{ .label = "动态验证码模态", .section = "ssh", .key = "otp_modal" },
    .{ .label = "TOTP 自动填充", .section = "ssh", .key = "totp_autofill" },
    .{ .label = "独立传输连接", .section = "transfer", .key = "dedicated_connection" },
    .{ .label = "共享通道限速", .section = "transfer", .key = "shared_pacing_kbps" },
    .{ .label = "滑动窗口", .section = "transfer", .key = "window_chunks" },
    .{ .label = "断点续传", .section = "transfer", .key = "resume" },
    .{ .label = "MD5 完成校验", .section = "transfer", .key = "verify_md5" },
    .{ .label = "最大并发任务", .section = "transfer", .key = "max_tasks" },
    .{ .label = "默认下载目录", .section = "transfer", .key = "download_dir" },
    .{ .label = "重命名冲突", .section = "transfer", .key = "conflict_policy" },
    .{ .label = "完成后系统通知", .section = "notify", .key = "transfer_done" },
    .{ .label = "默认权限模式", .section = "ai", .key = "permission_mode" },
    .{ .label = "默认运行方式", .section = "ai", .key = "execution_mode" },
    .{ .label = "任务会话处理", .section = "ai", .key = "session_retention" },
    .{ .label = "隐藏连接身份", .section = "ai", .key = "redact_ip" },
    .{ .label = "错误轻提示", .section = "ai", .key = "error_hint" },
    .{ .label = "传输完成", .section = "notify", .key = "transfer_done" },
    .{ .label = "断线与重连", .section = "notify", .key = "reconnect" },
    .{ .label = "AI 诊断就绪", .section = "notify", .key = "ai_ready" },
    .{ .label = "终端 Bell", .section = "notify", .key = "bell" },
    .{ .label = "非活跃标签圆点", .section = "notify", .key = "tab_dot" },
    .{ .label = "勿扰时段", .section = "notify", .key = "quiet_hours" },
    .{ .label = "配置目录", .section = "data", .key = "config_dir" },
    .{ .label = "环形缓冲上限", .section = "log", .key = "ring_mb" },
    .{ .label = "快照间隔", .section = "log", .key = "checkpoint_sec" },
    .{ .label = "日志保留天数", .section = "log", .key = "retention_days" },
    .{ .label = "导出格式", .section = "log", .key = "export_format" },
};

/// Owns its field id so the old page scope can be disposed before restoration.
/// Offsets follow Input's public UTF-8 selection contract, including direction.
pub const FocusSnapshot = struct {
    field_id: []u8,
    cursor_utf8: u32,
    anchor_utf8: ?u32,

    pub fn deinit(self: *FocusSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.field_id);
        self.* = undefined;
    }
};

pub const Mounted = struct {
    root: *ui.Node,
    scroll_state: *ui.widgets.scroll_area.ScrollState,
    scroll_container: *ui.Node,
    scroll_content: *ui.Node,
    save_button: *ui.Node,
    reset_button: *ui.Node,
    status_label: *ui.Node,
    binding: *Binding,

    pub fn refreshFooter(self: Mounted) void {
        self.binding.refreshFooter();
    }
    pub fn isComposing(self: Mounted) bool {
        return self.binding.isComposing();
    }
    /// Capture only a registered field. The host defers a remount while IME is
    /// composing; this snapshot never attempts to migrate native preedit.
    pub fn captureFocus(self: Mounted, allocator: std.mem.Allocator) !?FocusSnapshot {
        const focused = self.binding.cx.focus_manager.getFocused() orelse return null;
        for (self.binding.ime_clients.items) |input| {
            const node = input.input_container_node orelse continue;
            if (node != focused or input.disabled or input.imeIsComposing()) continue;
            const field_id = node.meta.ownership.meta.test_id orelse return null;
            return .{
                .field_id = try allocator.dupe(u8, field_id),
                .cursor_utf8 = @intCast(input.cursor_pos),
                .anchor_utf8 = if (input.selection_anchor) |anchor| @intCast(anchor) else null,
            };
        }
        return null;
    }
    /// Match the same registered field, without searching widget internals or
    /// taking focus from a control explicitly focused by the new page.
    pub fn restoreFocus(self: Mounted, snapshot: FocusSnapshot) bool {
        for (self.binding.ime_clients.items) |input| {
            const node = input.input_container_node orelse continue;
            const field_id = node.meta.ownership.meta.test_id orelse continue;
            if (!std.mem.eql(u8, field_id, snapshot.field_id)) continue;
            if (input.disabled or !node.behavior.interaction.focusable or input.imeIsComposing()) return false;
            if (self.binding.cx.focus_manager.getFocused()) |focused| if (focused != node) return false;
            self.binding.cx.setFocus(node);
            return input.setAccessibilitySelection(snapshot.anchor_utf8 orelse snapshot.cursor_utf8, snapshot.cursor_utf8);
        }
        return false;
    }
    /// Host capture calls this before closing the settings shell. It gives
    /// inner popovers and in-place fields their first Escape operation.
    pub fn consumeEscape(self: Mounted) bool {
        return self.binding.consumeEscape();
    }
};

pub fn mountContent(cx: *ui.Cx, scope: *ui.Scope, controller: *Controller, hooks: Hooks) !*ui.Node {
    return (try mountPage(cx, scope, controller, hooks)).root;
}

pub const MaterialPreview = struct {
    root: *ui.Node,
    binding: *Binding,
    pub fn refreshFooter(self: MaterialPreview) void {
        self.binding.refreshFooter();
    }
};
/// Mount inside the host's 660px action bar at the bottom of its window-wide
/// material preview. The same Controller/Hooks are retained on return.
pub fn mountMaterialPreviewActions(cx: *ui.Cx, scope: *ui.Scope, controller: *Controller, hooks: Hooks) !MaterialPreview {
    const bound = try Binding.init(cx, scope, controller, hooks);
    return .{ .root = try @import("settings_parts/appearance_view.zig").mountMaterialPreviewActions(cx, scope, bound), .binding = bound };
}

pub fn mountPage(cx: *ui.Cx, scope: *ui.Scope, controller: *Controller, hooks: Hooks) !Mounted {
    const binding = try Binding.init(cx, scope, controller, hooks);
    const root = try ui.boxStyled(cx, styles.content, .{});
    root.meta.ownership.meta.test_id = "settings.content";
    const header = try ui.boxStyled(cx, styles.header, .{});
    const heading = try ui.box(cx, .{ .width = .fill(), .min_width = 0, .flex = 1, .direction = .column, .gap = 4 }, .{});
    const searching = std.mem.trim(u8, controller.search_query, " \t\r\n").len != 0;
    try heading.appendChild(cx.allocator, try ui.text(cx, if (searching) "搜索结果" else controller.model.page().name, .{ .font_size = 13, .font_weight = 700, .line_height = 20.0 / 13.0, .color = styles.theme.current().fg_1 }));
    try heading.appendChild(cx.allocator, try ui.text(cx, if (searching) "在全部设置分类中查找，输入内容不会改变折叠偏好。" else controller.model.page().description, .{ .font_size = 11, .color = styles.theme.current().fg_2 }));
    try header.appendChild(cx.allocator, heading);
    const help_text = controller.model.page().description;
    const help = try ui.widgets.Tooltip(.{ .text = help_text, .open_delay_ms = 450 }).mount(scope, cx);
    help.content.meta.ownership.meta.test_id = "settings.help.content";
    const help_button = try ui.widgets.Button(.{ .icon_asset = ui.icons.circle_help, .icon_only = true, .a11y_label = "分类帮助", .variant = .ghost, .base_style = styles.fieldHelpButton(), .hover_style = styles.buttonHover() }).mount(scope, cx);
    help_button.meta.ownership.meta.test_id = "settings.help";
    try help.trigger.appendChild(cx.allocator, help_button);
    try header.appendChild(cx.allocator, help.wrapper);
    try root.appendChild(cx.allocator, header);
    const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
    scroll.container.style.flex = 1;
    scroll.container.style.flex_shrink = 1;
    scroll.container.style.margin.top = styles.geometry.viewport_gap;
    scroll.container.meta.ownership.meta.test_id = "settings.viewport";
    scroll.content.style.padding = .{ .left = 5, .right = 5, .bottom = 12 };
    scroll.content.style.gap = styles.geometry.section_gap;
    const page = try mountBody(cx, binding);
    try scroll.content.appendChild(cx.allocator, page);
    try root.appendChild(cx.allocator, scroll.container);
    const footer = try ui.boxStyled(cx, styles.footer, .{});
    footer.meta.ownership.meta.test_id = "settings.footer";
    const reset = try binding.actionButton(cx, .reset_defaults, ui.icons.rotate_ccw, "恢复默认…", "settings.reset", false);
    try footer.appendChild(cx.allocator, reset.wrapper);
    const state_text = footerStateText(controller);
    try footer.appendChild(cx.allocator, try ui.iconTint(cx, if (controller.model.dirty or backgroundNeedsAttention(controller)) ui.icons.circle else ui.icons.check, styles.theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }));
    const state_label = try ui.textStyled(cx, styles.note, state_text);
    binding.status_label = state_label;
    state_label.meta.ownership.meta.test_id = "settings.footer.state";
    try footer.appendChild(cx.allocator, state_label);
    try footer.appendChild(cx.allocator, try ui.spacer(cx));
    const revert = try binding.actionButton(cx, .revert, ui.icons.rotate_ccw, "撤销更改", "settings.revert", false);
    const save = try binding.actionButton(cx, .save, ui.icons.save, "保存更改", "settings.save", true);
    try footer.appendChild(cx.allocator, revert.wrapper);
    try footer.appendChild(cx.allocator, save.wrapper);
    try root.appendChild(cx.allocator, footer);
    binding.refreshFooter();
    return .{ .root = root, .scroll_state = scroll.state, .scroll_container = scroll.container, .scroll_content = scroll.content, .save_button = save.button, .reset_button = reset.button, .status_label = state_label, .binding = binding };
}

fn backgroundNeedsAttention(controller: *const Controller) bool {
    return controller.model.value.ui.materials.background.enabled and controller.background.problem != null;
}

fn footerStateText(controller: *const Controller) []const u8 {
    return switch (controller.state()) {
        // A failed replacement retains the committed typed path, so Config can
        // remain clean while the selected resource still needs attention.
        .clean => if (backgroundNeedsAttention(controller)) "背景图片准备失败，草稿已保留" else "已保存",
        .dirty_valid => "未保存",
        .dirty_invalid => "请修正设置中的错误",
        .saving => "正在保存…",
        .save_failed => controller.last_error orelse "保存失败，草稿已保留",
    };
}

fn mountBody(cx: *ui.Cx, binding: *Binding) !*ui.Node {
    if (std.mem.trim(u8, binding.controller.search_query, " \t\r\n").len == 0) return mountCategory(cx, binding, binding.controller.model.page_index);
    const results = try ui.boxStyled(cx, styles.sectionColumn, .{});
    results.meta.ownership.meta.test_id = "settings.search.results";
    var found_results = false;
    for (0..8) |index| {
        const page = try mountCategory(cx, binding, index);
        const empty = page.children.items.len == 1 and page.children.items[0].getText() != null and std.mem.eql(u8, page.children.items[0].getText().?.content, "没有匹配的设置");
        if (empty) page.setDisplay(.none) else found_results = true;
        try results.appendChild(cx.allocator, page);
    }
    if (!found_results) try results.appendChild(cx.allocator, try ui.textStyled(cx, styles.note, "没有匹配的设置"));
    return results;
}
fn mountCategory(cx: *ui.Cx, binding: *Binding, index: usize) !*ui.Node {
    const query = binding.controller.search_query;
    const names = [_][]const u8{ "外观与主题", "快捷键", "SSH 与网络", "文件传输", "AI 辅助", "协议插件", "通知", "数据与日志" };
    const folds = binding.controller.folded_sections;
    if (query.len != 0 and matches(query, names[index])) {
        binding.controller.search_query = "";
        binding.controller.folded_sections = 0;
    }
    defer {
        binding.controller.search_query = query;
        binding.controller.folded_sections = folds;
    }
    return switch (index) {
        0 => @import("settings_parts/settings.zig").mountContent(cx, binding),
        1 => @import("settings_parts/settings_keys.zig").mountContent(cx, binding),
        2 => @import("settings_parts/settings_ssh.zig").mountContent(cx, binding),
        3 => @import("settings_parts/settings_transfer.zig").mountContent(cx, binding),
        4 => @import("settings_parts/settings_ai.zig").mountContent(cx, binding),
        5 => @import("settings_parts/settings_plugins.zig").mountContent(cx, binding),
        6 => @import("settings_parts/settings_notify.zig").mountContent(cx, binding),
        else => @import("settings_parts/settings_data.zig").mountContent(cx, binding),
    };
}

pub fn matches(query: []const u8, text: []const u8) bool {
    const needle = std.mem.trim(u8, query, " \t\r\n");
    if (needle.len == 0) return true;
    if (needle.len > text.len) return false;
    for (0..text.len - needle.len + 1) |start| if (std.ascii.eqlIgnoreCase(needle, text[start..][0..needle.len])) return true;
    return false;
}
fn matchesText(node: *ui.Node, query: []const u8) bool {
    if (node.getText()) |text| if (matches(query, text.content)) return true;
    for (node.children.items) |child| if (matchesText(child, query)) return true;
    return false;
}

/// Transitional content pages keep their business bindings until their own
/// feature version. Only their old shell/title/footer is removed here.
fn normalizeLegacy(cx: *ui.Cx, binding: *Binding, page: *ui.Node) void {
    if (binding.legacy_save) |save| if (save.parent) |footer| if (footer.parent) |parent| {
        cx.detachChild(parent, footer);
        cx.destroyDetached(footer);
    };
    stripLegacyHeading(cx, page, binding.controller.model.page().name);
    normalizeContainer(page);
    for (page.children.items) |child| {
        if (child.style.height == .px and (child.style.height.px == 622 or child.style.height.px == 568)) normalizeContainer(child);
    }
}
fn normalizeContainer(node: *ui.Node) void {
    node.style.height = .{ .fit = .{} };
    node.style.width = .fill();
    node.style.flex = 0;
    node.style.flex_shrink = 0;
    node.style.padding = .ZERO;
    node.style.overflow = .visible;
    node.style.overflow_hidden = false;
}
fn stripLegacyHeading(cx: *ui.Cx, node: *ui.Node, name: []const u8) void {
    if (node.children.items.len >= 2 and matchesText(node.children.items[0], name)) {
        for (0..2) |_| {
            const child = node.children.items[0];
            cx.detachChild(node, child);
            cx.destroyDetached(child);
        }
        return;
    }
    for (node.children.items) |child| stripLegacyHeading(cx, child, name);
}

pub const Binding = struct {
    controller: *Controller,
    hooks: Hooks,
    scope: *ui.Scope,
    legacy_save: ?*ui.Node = null,
    cx: *ui.Cx,
    save_disabled: *ui.Signal(bool),
    revert_disabled: *ui.Signal(bool),
    save_tint: *ui.Signal(?ui.Color),
    save_style: *ui.Signal(styles.ButtonStyle),
    saving: *ui.Signal(bool),
    status_label: ?*ui.Node = null,
    font_status_label: ?*ui.Node = null,
    ime_clients: std.ArrayList(*ui.widgets.input.TextInputState) = .empty,
    popovers: std.ArrayList(struct { open: ui.Source(bool), close: ui.Handler(void) }) = .empty,
    tooltips: std.ArrayList(*ui.Signal(bool)) = .empty,
    escape_clients: std.ArrayList(struct { state: *ui.widgets.input.TextInputState, context: *anyopaque, cancel: *const fn (*anyopaque) void }) = .empty,
    fn init(cx: *ui.Cx, scope: *ui.Scope, controller: *Controller, hooks: Hooks) !*Binding {
        const self = try scope.allocator.create(Binding);
        errdefer scope.allocator.destroy(self);
        self.* = .{ .controller = controller, .hooks = hooks, .scope = scope, .cx = cx, .save_disabled = try scope.createSignal(bool, true), .revert_disabled = try scope.createSignal(bool, true), .save_tint = try scope.createSignal(?ui.Color, styles.theme.current().fg_2), .save_style = try scope.createSignal(styles.ButtonStyle, saveButtonStyle(false)), .saving = try scope.createSignal(bool, controller.state() == .saving) };
        try scope.onCleanup(Binding, self, Binding.cleanup);
        self.refreshFooter();
        return self;
    }
    fn saveButtonStyle(available: bool) styles.ButtonStyle {
        var result = styles.textButton();
        result.height = .{ .px = 32 };
        result.padding = .{ .left = 12, .right = 12 };
        result.width = .{ .px = 92 };
        result.font_size = 12;
        result.font_weight = 500;
        result.gap = 6;
        result.background = styles.theme.current().action_accent;
        result.gradient = .{ .from = styles.theme.current().action_accent, .to = styles.theme.current().action_accent_2, .direction = .diagonal };
        result.text_color = styles.theme.actionForeground(styles.theme.current().action_accent);
        result.opacity = if (available) 1 else 0.4;
        return result;
    }
    fn cleanup(self: *Binding) void {
        self.ime_clients.deinit(self.scope.allocator);
        self.popovers.deinit(self.scope.allocator);
        self.tooltips.deinit(self.scope.allocator);
        self.escape_clients.deinit(self.scope.allocator);
        self.scope.allocator.destroy(self);
    }
    pub fn registerInput(self: *Binding, state: *ui.widgets.input.TextInputState) !void {
        try self.ime_clients.append(self.scope.allocator, state);
    }
    pub fn isComposing(self: *const Binding) bool {
        for (self.ime_clients.items) |client| if (client.imeIsComposing()) return true;
        return false;
    }
    pub fn registerPopover(self: *Binding, result: ui.widgets.popover.PopoverResult) !void {
        try self.popovers.append(self.scope.allocator, .{ .open = result.open_read, .close = result.close });
    }
    pub fn registerTooltip(self: *Binding, open: *ui.Signal(bool)) !void {
        try self.tooltips.append(self.scope.allocator, open);
    }
    pub fn registerEscape(self: *Binding, state: *ui.widgets.input.TextInputState, context: *anyopaque, cancel: *const fn (*anyopaque) void) !void {
        try self.escape_clients.append(self.scope.allocator, .{ .state = state, .context = context, .cancel = cancel });
    }
    pub fn consumeEscape(self: *Binding) bool {
        if (self.isComposing()) return false;
        var tooltip_index = self.tooltips.items.len;
        while (tooltip_index > 0) {
            tooltip_index -= 1;
            const open = self.tooltips.items[tooltip_index];
            if (open.peek()) {
                open.set(false);
                return true;
            }
        }
        var index = self.popovers.items.len;
        while (index > 0) {
            index -= 1;
            const popover = self.popovers.items[index];
            if (popover.open.read(false)) {
                popover.close.invoke();
                return true;
            }
        }
        const focused = self.cx.focus_manager.getFocused() orelse return false;
        for (self.escape_clients.items) |client| if (client.state.input_container_node == focused) {
            client.cancel(client.context);
            self.cx.setFocus(null);
            return true;
        };
        return false;
    }
    pub fn refreshFooter(self: *Binding) void {
        var available = self.controller.canSave();
        if (self.hooks.appearance) |host| {
            if (host.isBusy()) available = false;
            if (host.font_status) |read_font| {
                const font = read_font(host.context);
                if (font.problem != null) available = false;
                if (self.font_status_label) |label| {
                    var buffer: [256]u8 = undefined;
                    const message = if (font.problem) |problem| problem else if (font.fallback) std.fmt.bufPrint(&buffer, "字体缺失 · 实际使用 {s}", .{font.actual_family}) catch "字体缺失 · 使用系统回退" else "";
                    label.setTextContent(self.cx.allocator, message) catch {};
                    label.setDisplay(if (message.len == 0) .none else .flex);
                }
            }
        }
        self.revert_disabled.set(!self.controller.model.dirty or self.controller.state() == .saving or if (self.hooks.appearance) |host| host.isBusy() else false);
        self.save_style.set(saveButtonStyle(available));
        self.save_disabled.set(!available);
        self.save_tint.set(styles.theme.actionForeground(styles.theme.current().action_accent));
        self.saving.set(self.controller.state() == .saving);
        var message = footerStateText(self.controller);
        // Native permission callbacks outlive a field refresh and can rebuild
        // this page. Keep their feedback separate from save/validation state.
        if (self.controller.model.page_index == 6 and (self.controller.state() == .clean or self.controller.state() == .dirty_valid)) {
            if (self.hooks.authorization_feedback) |read_feedback| {
                if (read_feedback(self.hooks.context)) |feedback| message = feedback;
            }
        }
        if (self.status_label) |label| label.setTextContent(self.cx.allocator, message) catch {};
    }
    pub fn valuesChanged(self: *Binding) void {
        self.refreshFooter();
        if (self.hooks.appearance) |appearance| appearance.send(.draft_values_changed);
        self.cx.requestRedraw();
    }

    fn read(self: *Binding, key: Key) ?values.Value {
        if (self.hooks.read) |callback| if (callback(self.hooks.context, key)) |value| return value;
        if (std.mem.eql(u8, key.section, "data") and std.mem.eql(u8, key.key, "config_dir")) return .{ .text = "由应用管理" };
        if (std.mem.eql(u8, key.section, "completion")) return .{ .boolean = self.controller.model.value.completion.enabled };
        return values.read(self.controller.model.value, key.section, key.key);
    }
    fn edit(self: *Binding, key: Key, value: values.Value) void {
        if (self.controller.state() == .saving) return;
        if (self.hooks.edit) |callback| {
            callback(self.hooks.context, key, value);
        } else {
            self.controller.editKey(key.section, key.key, value) catch return;
        }
        self.hooks.changed(self.hooks.context);
    }
    pub fn control(self: *Binding, cx: *ui.Cx, label: []const u8, shell: *ui.Node) !*ui.Node {
        for (rows) |row| {
            if (!std.mem.eql(u8, label, row.label)) continue;
            const key = Key{ .section = row.section, .key = row.key };
            const value = self.read(key);
            const node = shell;
            if (value) |current| {
                switch (current) {
                    .boolean => |enabled| {
                        const track = findToggle(shell) orelse shell;
                        track.setBackground(if (enabled) design.tok.acc else design.tok.off_dot);
                        track.style.justify = if (enabled) .end else .start;
                    },
                    else => {
                        const leaf = firstText(shell) orelse shell;
                        var buffer: [192]u8 = undefined;
                        const shown = try self.display(&buffer, key, current);
                        var arrow_buffer: [256]u8 = undefined;
                        const old = leaf.getText();
                        const text = if (old != null and std.mem.endsWith(u8, old.?.content, "▾")) try std.fmt.bufPrint(&arrow_buffer, "{s} ▾", .{shown}) else shown;
                        try leaf.setTextContent(cx.allocator, text);
                    },
                }
            }
            if (value == null) {
                if (findToggle(shell)) |track| {
                    track.setBackground(design.tok.off_dot);
                    track.style.justify = .start;
                } else if (firstText(shell)) |leaf| {
                    try leaf.setTextContent(cx.allocator, "—");
                }
            }
            if (schema.find(key.section, key.key)) |index| {
                const field = self.controller.raw_fields[index];
                if (field.problem != null) {
                    shell.style.border.width = 0;
                    shell.setBackground(styles.theme.current().danger.withAlpha(23));
                    shell.style.border.color = styles.theme.current().danger_ink;
                    if (field.input) |input| if (firstText(shell)) |leaf| try leaf.setTextContent(cx.allocator, input);
                }
            }
            const click = try cx.allocator.create(Click);
            try self.scope.onCleanup(Click, click, Click.cleanup);
            click.* = .{ .binding = self, .key = key, .node = node };
            node.behavior.events.on_click = .{ .callback = Click.run, .context = @ptrCast(click) };
            return node;
        }
        return shell;
    }
    fn display(self: *Binding, buffer: []u8, key: Key, value: values.Value) ![]const u8 {
        if (std.mem.eql(u8, key.key, "window_chunks")) return std.fmt.bufPrint(buffer, "{d} × {d} KB", .{ self.controller.model.value.transfer.window_chunks, self.controller.model.value.transfer.chunk_kb });
        if (std.mem.eql(u8, key.key, "reconnect_backoff")) {
            const seq = self.controller.model.value.ssh.reconnect_backoff;
            return std.fmt.bufPrint(buffer, "{d}→{d}→{d}→{d}→{d}s", .{ seq[0], seq[1], seq[2], seq[3], seq[4] });
        }
        return switch (value) {
            .text => |text| blk: {
                if (std.mem.eql(u8, key.key, "execution_mode")) break :blk config.executionModeLabel(self.controller.model.value.ai.execution_mode);
                if (std.mem.eql(u8, key.key, "session_retention")) break :blk config.sessionRetentionLabel(self.controller.model.value.ai.session_retention);
                if (std.mem.eql(u8, key.key, "permission_mode")) break :blk if (std.mem.eql(u8, text, "auto")) "自动执行" else "确认后执行";
                if (std.mem.eql(u8, key.key, "cursor_style")) break :blk if (std.mem.eql(u8, text, "bar")) "▏ Bar" else if (std.mem.eql(u8, text, "underline")) "▁ Underline" else "█ Block";
                if (std.mem.eql(u8, key.key, "conflict_policy")) break :blk "每次询问";
                if (std.mem.eql(u8, key.key, "export_format")) break :blk if (std.mem.eql(u8, text, "txt_cast")) ".txt / .cast" else if (std.mem.eql(u8, text, "cast")) ".cast" else ".txt";
                if (std.mem.eql(u8, key.key, "quiet_hours") and text.len == 11) break :blk try std.fmt.bufPrint(buffer, "{s} – {s}", .{ text[0..5], text[6..11] });
                break :blk text;
            },
            .unsigned => |number| std.fmt.bufPrint(buffer, "{d}{s}", .{ number, if (std.mem.eql(u8, key.key, "font_size")) " pt" else if (std.mem.endsWith(u8, key.key, "_sec")) " 秒" else if (std.mem.eql(u8, key.key, "reconnect_max")) " 次" else if (std.mem.eql(u8, key.key, "ring_mb")) " MB" else if (std.mem.eql(u8, key.key, "shared_pacing_kbps")) " KB/s" else if (std.mem.eql(u8, key.key, "retention_days")) " 天" else "" }),
            .decimal => |number| std.fmt.bufPrint(buffer, "{d}", .{number}),
            .boolean => unreachable,
        };
    }
    pub fn actionNode(self: *Binding, cx: *ui.Cx, action: Action, node: *ui.Node) !*ui.Node {
        if (action == .save) self.legacy_save = node;
        const click = try cx.allocator.create(ActionClick);
        try self.scope.onCleanup(ActionClick, click, ActionClick.cleanup);
        click.* = .{ .binding = self, .action = action };
        node.behavior.events.on_click = .{ .callback = ActionClick.run, .context = @ptrCast(click) };
        return node;
    }
    pub fn actionButton(self: *Binding, cx: *ui.Cx, action: Action, icon: ui.SvgAsset, label: []const u8, id: []const u8, primary: bool) !struct { wrapper: *ui.Node, button: *ui.Node } {
        const click = try cx.allocator.create(ActionClick);
        click.* = .{ .binding = self, .action = action };
        try self.scope.onCleanup(ActionClick, click, ActionClick.cleanup);
        const tip = try ui.widgets.Tooltip(.{ .text = label, .open_delay_ms = 450 }).mount(self.scope, cx);
        var style = styles.textButton();
        style.height = .{ .px = 32 };
        style.padding = .{ .left = 8, .right = 8 };
        style.background = if (primary) styles.theme.current().action_accent else ui.Color.TRANSPARENT;
        style.text_color = if (primary) styles.theme.actionForeground(styles.theme.current().action_accent) else styles.theme.current().fg_2;
        const node = try ui.widgets.Button(.{ .label = label, .icon_asset = if (action == .reset_defaults) null else icon, .icon_size = @as(f32, 14), .icon_tint = if (primary) self.save_tint else try self.scope.createSignal(?ui.Color, styles.theme.current().fg_2), .a11y_label = label, .variant = @as(ui.widgets.ButtonVariant, if (primary) .primary else .secondary), .disabled = if (primary) self.save_disabled else if (action == .revert) self.revert_disabled else self.saving, .loading = if (primary) self.saving else try self.scope.createSignal(bool, false), .on_click = cx.on(ActionClick, click, ActionClick.activate), .base_style = @as(ui.Source(styles.ButtonStyle), if (primary) .{ .signal = self.save_style } else .{ .value = style }), .hover_style = @as(?ui.BoxStyle, if (primary) .{ .background = styles.theme.current().action_accent } else styles.buttonHover()), .pressed_style = @as(?ui.BoxStyle, if (primary) .{ .background = styles.theme.current().action_accent } else null) }).mount(self.scope, cx);
        node.meta.ownership.meta.test_id = id;
        if (primary) try self.scope.createEffect(.{ .bound = self, .node = node }, struct {
            fn run(args: anytype) void {
                const disabled = args.bound.save_disabled.get();
                const theme = styles.theme.current();
                args.node.setStyleInline(args.bound.cx.allocator, .{ .background = theme.action_accent, .gradient = .{ .from = theme.action_accent, .to = theme.action_accent_2, .direction = .diagonal }, .opacity = if (disabled) @as(f32, 0.4) else @as(f32, 1) });
            }
        }.run);
        try tip.trigger.appendChild(cx.allocator, node);
        return .{ .wrapper = tip.wrapper, .button = node };
    }
    pub fn themeSelected(self: *Binding, name: []const u8) bool {
        return std.mem.eql(u8, self.controller.model.value.ui.theme, name);
    }
    pub fn weightSelected(self: *Binding, name: []const u8) bool {
        return std.mem.eql(u8, self.controller.model.value.ui.font_weight, name);
    }
    pub fn themeNode(self: *Binding, cx: *ui.Cx, name: []const u8, node: *ui.Node) !*ui.Node {
        const theme = if (std.mem.startsWith(u8, name, "Sauber")) "sauber" else if (std.mem.startsWith(u8, name, "Catppuccin")) "catppuccin-mocha" else "dracula";
        node.meta.ownership.meta.test_id = if (std.mem.eql(u8, theme, "sauber")) "settings.theme.sauber" else if (std.mem.eql(u8, theme, "catppuccin-mocha")) "settings.theme.catppuccin" else "settings.theme.dracula";
        return self.choice(cx, .{ .section = "ui", .key = "theme" }, theme, node);
    }
    pub fn weightNode(self: *Binding, cx: *ui.Cx, name: []const u8, node: *ui.Node) !*ui.Node {
        return self.choice(cx, .{ .section = "ui", .key = "font_weight" }, name, node);
    }
    fn choice(self: *Binding, cx: *ui.Cx, key: Key, value: []const u8, node: *ui.Node) !*ui.Node {
        const click = try cx.allocator.create(ChoiceClick);
        try self.scope.onCleanup(ChoiceClick, click, ChoiceClick.cleanup);
        click.* = .{ .binding = self, .key = key, .value = value };
        node.behavior.events.on_click = .{ .callback = ChoiceClick.run, .context = @ptrCast(click) };
        return node;
    }
    pub fn shortcut(self: *Binding, cx: *ui.Cx, label: []const u8, node: *ui.Node) !*ui.Node {
        if (std.mem.eql(u8, label, "页签") or std.mem.eql(u8, label, "终端")) return node;
        if (self.hooks.keybindings) |map| {
            var buffer: [256]u8 = undefined;
            if (firstText(node)) |leaf| try leaf.setTextContent(cx.allocator, try map.rowText(label, &buffer));
        } else if (self.hooks.shortcut_text) |callback| {
            var buffer: [256]u8 = undefined;
            if (firstText(node)) |leaf| try leaf.setTextContent(cx.allocator, try callback(self.hooks.context, label, &buffer));
        }
        const key = Key{ .section = "keys", .key = label };
        const click = try cx.allocator.create(Click);
        try self.scope.onCleanup(Click, click, Click.cleanup);
        click.* = .{ .binding = self, .key = key, .node = node };
        node.behavior.events.on_click = .{ .callback = Click.run, .context = @ptrCast(click) };
        return node;
    }
    pub fn providers(self: *Binding, cx: *ui.Cx) !*ui.Node {
        if (self.hooks.mount_providers) |callback| return callback(self.hooks.context, cx, self.scope);
        return error.ProviderViewRequired;
    }
};
fn findToggle(node: *ui.Node) ?*ui.Node {
    if (node.style.width == .px and node.style.width.px == 34 and node.style.height == .px and node.style.height.px == 19) return node;
    for (node.children.items) |child| if (findToggle(child)) |track| return track;
    return null;
}
fn firstText(node: *ui.Node) ?*ui.Node {
    if (node.getText() != null) return node;
    for (node.children.items) |child| if (firstText(child)) |text| return text;
    return null;
}
const Click = struct {
    fn cleanup(self: *Click) void {
        self.binding.scope.allocator.destroy(self);
    }
    binding: *Binding,
    key: Key,
    node: *ui.Node,
    fn run(raw: *anyopaque) void {
        const self: *Click = @ptrCast(@alignCast(raw));
        if (self.binding.controller.state() == .saving) return;
        if (std.mem.eql(u8, self.key.section, "data")) {
            self.binding.hooks.action(self.binding.hooks.context, .open_config_dir);
            return;
        }
        if (self.binding.read(self.key)) |value| {
            if (value == .boolean) {
                self.binding.edit(self.key, .{ .boolean = !value.boolean });
                return;
            }
        }
        self.binding.hooks.request_edit(self.binding.hooks.context, self.key, self.node);
    }
};
const ActionClick = struct {
    fn cleanup(self: *ActionClick) void {
        self.binding.scope.allocator.destroy(self);
    }
    binding: *Binding,
    action: Action,
    fn run(raw: *anyopaque) void {
        const self: *ActionClick = @ptrCast(@alignCast(raw));
        self.activate();
    }
    fn activate(self: *ActionClick) void {
        if (self.binding.controller.state() == .saving) return;
        if (self.action == .save and self.binding.save_disabled.get()) return;
        if (self.action == .revert and self.binding.revert_disabled.get()) return;
        self.binding.hooks.action(self.binding.hooks.context, self.action);
    }
};
const ChoiceClick = struct {
    fn cleanup(self: *ChoiceClick) void {
        self.binding.scope.allocator.destroy(self);
    }
    binding: *Binding,
    key: Key,
    value: []const u8,
    fn run(raw: *anyopaque) void {
        const self: *ChoiceClick = @ptrCast(@alignCast(raw));
        self.binding.edit(self.key, .{ .text = self.value });
    }
};
