const std = @import("std");
const ui = @import("ui");
const binding = @import("../settings_content_view.zig");
const S = @import("../settings_styles.zig");
const registry = @import("../../host/plugin_registry.zig");
const controls = @import("settings_controls.zig");

pub fn mountContent(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const root = try ui.boxStyled(cx, S.sectionColumn, .{});
    root.meta.ownership.meta.test_id = "settings.plugins";
    try mountList(cx, bound, root);
    return root;
}

const Card = struct { root: *ui.Node, body: *ui.Node };
fn card(cx: *ui.Cx, bound: *binding.Binding, title: []const u8, summary: []const u8, icon: ui.SvgAsset, bit: u6, initially_open: bool) !Card {
    const fold = try cx.allocator.create(Fold);
    fold.* = .{ .bound = bound, .bit = bit, .positive = initially_open };
    try bound.scope.onCleanup(Fold, fold, Fold.cleanup);
    const stored = (bound.controller.folded_sections & (@as(u64, 1) << bit)) != 0;
    const open = if (bound.controller.search_query.len != 0) true else if (initially_open) stored else !stored;
    const result = try ui.widgets.AccordionItem(.{ .title = title, .expanded = open, .on_change = ui.Handler(bool).from(Fold, fold, Fold.change), .variant = .ghost }).mount(bound.scope, cx);
    _ = try controls.sectionHeader(cx, bound.scope, result, icon, open, summary, title);
    const header = result.header;
    header.meta.ownership.meta.test_id = title;
    if (bound.controller.state() == .saving) {
        header.behavior.events.on_event = null;
        header.behavior.interaction.focusable = false;
    }
    result.body.style.padding = .{ .left = 16, .right = 16, .bottom = 8 };
    result.body.style.width = .fill();
    result.body.style.direction = .column;
    result.body.style.gap = 0;
    return .{ .root = result.item, .body = result.body };
}
const Fold = struct {
    bound: *binding.Binding,
    bit: u6,
    positive: bool,
    fn cleanup(self: *Fold) void {
        self.bound.scope.allocator.destroy(self);
    }
    fn change(self: *Fold, open: bool) void {
        if (self.bound.controller.state() == .saving) return;
        const mask = @as(u64, 1) << self.bit;
        const stored = if (self.positive) open else !open;
        if (stored) self.bound.controller.folded_sections |= mask else self.bound.controller.folded_sections &= ~mask;
        self.bound.hooks.changed(self.bound.hooks.context);
    }
};

fn mountList(cx: *ui.Cx, bound: *binding.Binding, root: *ui.Node) !void {
    const source = bound.controller.plugin_page.registry_source;
    const details = try mountDetails(cx, bound, root);
    var matched: usize = 0;
    for ([_]registry.Origin{ .builtin, .bundled }, 0..) |origin, group_index| {
        var count: usize = 0;
        for (source.manifests()) |entry| if (entry.origin == origin) {
            count += 1;
        };
        if (count == 0) continue;
        var summary_buffer: [96]u8 = undefined;
        const title: []const u8 = if (origin == .builtin) "已内置" else "随应用提供";
        const summary = try controls.owned(bound.scope, try std.fmt.bufPrint(&summary_buffer, "{d} 个协议 · 随应用管理", .{count}));
        const section = try card(cx, bound, title, summary, ui.icons.plug, @intCast(40 + group_index), group_index == 0);
        section.root.meta.ownership.meta.test_id = if (origin == .builtin) "settings.plugins.builtin" else "settings.plugins.bundled";
        section.body.meta.ownership.meta.test_id = if (origin == .builtin) "settings.plugins.builtin.body" else "settings.plugins.bundled.body";
        var group_matches: usize = 0;
        for (source.manifests()) |entry| {
            if (entry.origin != origin) continue;
            if (!binding.matches(bound.controller.search_query, entry.display_name) and !binding.matches(bound.controller.search_query, title)) continue;
            group_matches += 1;
            try section.body.appendChild(cx.allocator, try pluginRow(cx, bound, details, entry));
            if (entry.settings_section) |preferences| for (preferences.fields) |field| {
                try section.body.appendChild(cx.allocator, try preferenceRow(cx, bound, entry.id, field));
            };
        }
        if (group_matches != 0) {
            const note = try ui.text(cx, if (origin == .builtin) "内置协议随应用管理。" else "插件随应用管理。", .{ .font_size = 11, .line_height = 18.0 / 11.0, .color = S.theme.current().fg_2 });
            note.style.margin = .{ .top = 8, .bottom = 8 };
            try section.body.appendChild(cx.allocator, note);
        }
        matched += group_matches;
        if (group_matches != 0 or bound.controller.search_query.len == 0) try root.appendChild(cx.allocator, section.root) else cx.destroyDetached(section.root);
    }
    if (bound.controller.search_query.len == 0 or binding.matches(bound.controller.search_query, "协议扩展 BMC iKVM VNC RDP FTP")) {
        const future = try card(cx, bound, "协议扩展", "远程桌面、文件传输与带外管理", ui.icons.layers, 42, false);
        future.root.meta.ownership.meta.test_id = "settings.plugins.future";
        future.body.meta.ownership.meta.test_id = "settings.plugins.future.body";
        try future.body.appendChild(cx.allocator, try futureRow(cx, bound, "BMC iKVM", "远程查看服务器画面，使用键鼠控制和电源管理。", ui.icons.server));
        try future.body.appendChild(cx.allocator, try futureRow(cx, bound, "VNC / RDP / FTP", "连接远程桌面，或通过 FTP 传输文件。", ui.icons.layers));
        const note = try ui.text(cx, "连接配置通过连接编辑器管理。", .{ .font_size = 11, .line_height = 18.0 / 11.0, .color = S.theme.current().fg_2 });
        note.style.margin = .{ .top = 8, .bottom = 8 };
        try future.body.appendChild(cx.allocator, note);
        try root.appendChild(cx.allocator, future.root);
    }
    if (matched == 0) try root.appendChild(cx.allocator, try ui.textStyled(cx, S.note, if (bound.controller.search_query.len == 0) "没有已注册的插件" else "没有匹配的设置"));
}
pub fn description(entry: registry.PluginManifest) []const u8 {
    if (std.mem.eql(u8, entry.id, "local")) return "本机 Shell 与终端会话";
    if (std.mem.eql(u8, entry.id, "ssh")) return "远程终端、认证与端口转发";
    if (std.mem.eql(u8, entry.id, "sftp")) return "目录浏览、文件读写与文件传输";
    return entry.workspace_kind;
}
pub fn permissions(entry: registry.PluginManifest) []const u8 {
    if (std.mem.eql(u8, entry.id, "local")) return "允许本机 Shell 进程与当前目录访问；\n实际授权遵循 macOS 权限。";
    if (std.mem.eql(u8, entry.id, "ssh")) return "连接时按需读取钥匙串、进行网络连接及用户批准的转发。";
    if (std.mem.eql(u8, entry.id, "sftp")) return "按用户选择的路径访问本地文件，通过远端连接读写目录；传输任务可取消。";
    return "连接时按需请求权限";
}
fn pluginId(scope: *ui.Scope, plugin_id: []const u8, suffix: []const u8) ![]const u8 {
    const value = try std.fmt.allocPrint(scope.allocator, "settings.plugin.{s}.{s}", .{ plugin_id, suffix });
    defer scope.allocator.free(value);
    return controls.owned(scope, value);
}
fn pluginRow(cx: *ui.Cx, bound: *binding.Binding, details: *Info, entry: registry.PluginManifest) !*ui.Node {
    const row = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 66 }, .direction = .row, .align_items = .center, .gap = 10, .flex_shrink = 0, .min_width = 0 }, .{});
    row.meta.ownership.meta.test_id = try pluginId(bound.scope, entry.id, "row");
    const icon = @import("../../ui/session_icon.zig").asset(entry.icons.settings);
    try row.appendChild(cx.allocator, try ui.iconTint(cx, icon, S.theme.current().accent, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 }));
    const labels = try ui.box(cx, .{ .width = .fill(), .flex = 1, .min_width = 0, .direction = .column, .gap = 3 }, .{});
    const name = try ui.text(cx, entry.display_name, .{ .font_size = 12, .font_weight = 500, .line_height = 1.5, .color = S.theme.current().fg_1 });
    name.meta.ownership.meta.test_id = try pluginId(bound.scope, entry.id, "name");
    try labels.appendChild(cx.allocator, name);
    const detail = try ui.text(cx, description(entry), .{ .font_size = 11, .line_height = 18.0 / 11.0, .color = S.theme.current().fg_2, .wrap = .word });
    detail.style.width = .fill();
    detail.meta.ownership.meta.test_id = try pluginId(bound.scope, entry.id, "description");
    try labels.appendChild(cx.allocator, detail);
    try row.appendChild(cx.allocator, labels);
    const tag = try ui.widgets.Tag(.{ .label = if (entry.origin == .builtin) @as([]const u8, "内置") else "随应用提供", .color = .neutral, .size = .sm }).mount(bound.scope, cx);
    tag.setStyleInline(cx.allocator, .{ .height = .{ .px = 22 }, .padding = .{ .left = 6, .right = 6, .top = 3, .bottom = 3 }, .background = S.theme.current().hover, .border = .{ .radius = 5 }, .flex_shrink = 0 });
    for (tag.children.items) |child| if (child.getText()) |old| {
        var text = old;
        text.font_size = 10;
        text.color = S.theme.current().fg_2;
        child.setText(text);
    };
    try row.appendChild(cx.allocator, tag);
    var buffer: [256]u8 = undefined;
    const version_title = try controls.owned(bound.scope, try std.fmt.bufPrint(&buffer, "{s} · {s}", .{ entry.display_name, entry.plugin_version }));
    try row.appendChild(cx.allocator, try infoButton(cx, bound, details, entry, "version", entry.plugin_version, version_title, "静态链接插件随应用管理", false));
    const permission_title = try controls.owned(bound.scope, try std.fmt.bufPrint(&buffer, "{s} · 权限", .{entry.display_name}));
    try row.appendChild(cx.allocator, try infoButton(cx, bound, details, entry, "permissions", "", permission_title, permissions(entry), true));
    return row;
}

const PreferenceControl = struct {
    bound: *binding.Binding,
    plugin_id: []const u8,
    key: []const u8,
    message: *ui.Node,
    options: []ui.widgets.SelectOption = &.{},
    fn cleanup(self: *PreferenceControl) void {
        self.bound.scope.allocator.free(self.options);
        self.bound.scope.allocator.destroy(self);
    }
    fn edit(self: *PreferenceControl, value: []const u8) void {
        if (self.bound.controller.state() == .saving) return;
        self.bound.controller.setPluginPreference(self.plugin_id, self.key, value) catch |err| {
            self.message.setTextContent(self.bound.cx.allocator, @errorName(err)) catch {};
            self.message.setDisplay(.flex);
            self.bound.valuesChanged();
            return;
        };
        self.message.setDisplay(.none);
        self.bound.valuesChanged();
    }
    fn toggle(self: *PreferenceControl, checked: bool) void {
        self.edit(if (checked) "true" else "false");
    }
    fn select(self: *PreferenceControl, value: ?[]const u8) void {
        self.edit(value orelse return);
    }
};
fn preferenceRow(cx: *ui.Cx, bound: *binding.Binding, plugin_id: []const u8, field: registry.PreferenceField) !*ui.Node {
    const root = try ui.boxStyled(cx, S.column, .{});
    const row = try ui.boxStyled(cx, S.fieldRow, .{});
    try root.appendChild(cx.allocator, row);
    const labels = try ui.boxStyled(cx, S.fieldLabel, .{});
    try row.appendChild(cx.allocator, labels);
    try labels.appendChild(cx.allocator, try ui.textStyled(cx, S.label, field.label));
    try labels.appendChild(cx.allocator, try ui.textStyled(cx, S.note, if (field.apply_timing == .next_connection) "下次连接生效" else "保存后生效"));
    const message = try ui.textStyled(cx, S.note, "");
    message.setDisplay(.none);
    try root.appendChild(cx.allocator, message);
    const state = try bound.scope.allocator.create(PreferenceControl);
    state.* = .{ .bound = bound, .plugin_id = plugin_id, .key = field.key, .message = message };
    try bound.scope.onCleanup(PreferenceControl, state, PreferenceControl.cleanup);
    const current = bound.controller.model.value.pluginPreference(plugin_id, field.key) orelse field.default_value orelse "";
    const id_text = try std.fmt.allocPrint(cx.allocator, "settings.plugin.{s}.{s}", .{ plugin_id, field.key });
    defer cx.allocator.free(id_text);
    const test_id = try controls.owned(bound.scope, id_text);
    switch (field.kind) {
        .boolean => {
            const checked = try bound.scope.createSignal(bool, std.mem.eql(u8, current, "true"));
            const node = try ui.widgets.Switch(.{ .checked = checked, .disabled = bound.saving, .on_change = cx.on(PreferenceControl, state, PreferenceControl.toggle) }).mount(bound.scope, cx);
            node.meta.ownership.meta.test_id = test_id;
            if (node.behavior.interaction.a11y) |*a11y| a11y.label = field.label;
            try row.appendChild(cx.allocator, node);
            try bound.scope.createEffect(.{ .cx = cx, .node = node, .checked = checked }, struct {
                fn run(args: anytype) void {
                    S.paintSwitch(args.cx, args.node, args.checked.get());
                }
            }.run);
        },
        .string => {
            const value = try bound.scope.createText(current, .{});
            var input = try ui.widgets.Input(.{ .value = value, .disabled = bound.saving, .on_change = cx.on(PreferenceControl, state, PreferenceControl.edit) }).mountResult(bound.scope, cx);
            input.input_container.setStyleInline(cx.allocator, S.fieldControl(undefined));
            input.node.meta.ownership.meta.test_id = test_id;
            input.node.style.width = .{ .px = S.geometry.control_width };
            S.tuneInput(&input);
            try bound.registerInput(input.state);
            try row.appendChild(cx.allocator, input.node);
        },
        .choice => {
            state.options = try bound.scope.allocator.alloc(ui.widgets.SelectOption, field.options.len);
            for (state.options, field.options) |*destination, option| destination.* = .{ .value = option.value, .label = option.label };
            const value = try bound.scope.createSignal(?[]const u8, try controls.owned(bound.scope, current));
            const select = try ui.widgets.Select(.{ .options = state.options, .value = value, .disabled = bound.saving, .on_change = cx.on(PreferenceControl, state, PreferenceControl.select) }).mount(bound.scope, cx);
            select.trigger.setStyleInline(cx.allocator, S.fieldControl(undefined));
            select.trigger.meta.ownership.meta.test_id = test_id;
            S.tuneSelect(select);
            if (select.open) |open| try bound.registerTooltip(open);
            try row.appendChild(cx.allocator, select.wrapper);
        },
    }
    return root;
}

const Info = struct {
    scope: *ui.Scope,
    cx: *ui.Cx,
    open: *ui.Signal(bool),
    modal: ui.widgets.ModalResult,
    title: *ui.Node,
    message: *ui.Node,
    header: *ui.Node,
    viewport: *ui.Node,
    footer: *ui.Node,
    close_button: *ui.Node,
    fn cleanup(self: *Info) void {
        self.scope.allocator.destroy(self);
    }
    fn close(self: *Info) void {
        self.open.set(false);
    }
};
const InfoAction = struct {
    scope: *ui.Scope,
    info: *Info,
    title: []const u8,
    message: []const u8,
    ids: [7][]const u8,
    fn cleanup(self: *InfoAction) void {
        self.scope.allocator.destroy(self);
    }
    fn invalidate(node: *ui.Node) void {
        node.invalidateRenderCache();
        node.invalidateSubtreePayloadCache();
        node.markRenderDirty();
        for (node.children.items) |child| invalidate(child);
    }
    fn show(self: *InfoAction) void {
        const info = self.info;
        info.title.setTextContent(info.cx.allocator, self.title) catch return;
        info.message.setTextContent(info.cx.allocator, self.message) catch return;
        const nodes = [_]*ui.Node{ info.modal.overlay, info.modal.dialog, info.header, info.message, info.viewport, info.footer, info.close_button };
        for (nodes, self.ids) |node, id| node.meta.ownership.meta.test_id = id;
        if (info.modal.dialog.behavior.interaction.a11y) |*a11y| a11y.label = self.title;
        info.open.set(true);
        invalidate(info.modal.overlay);
    }
};
fn mountDetails(cx: *ui.Cx, bound: *binding.Binding, root: *ui.Node) !*Info {
    const state = try bound.scope.allocator.create(Info);
    const open = try bound.scope.createSignal(bool, false);
    const modal = try ui.widgets.Modal(.{ .open = open, .width = @as(f32, 390), .max_height = @as(f32, 240), .background = S.theme.current().overlay, .close_on_overlay = true, .enter_transition = .none, .exit_transition = .none }).mount(bound.scope, cx);
    state.* = .{ .scope = bound.scope, .cx = cx, .open = open, .modal = modal, .title = undefined, .message = undefined, .header = undefined, .viewport = undefined, .footer = undefined, .close_button = undefined };
    try bound.scope.onCleanup(Info, state, Info.cleanup);
    try bound.registerTooltip(open);
    modal.dialog.setStyleInline(cx.allocator, .{ .width = .{ .px = 390 }, .height = .{ .px = 208 }, .max_height = 240, .padding = .{}, .direction = .column, .gap = 0, .background = S.theme.current().overlay, .border = .{ .radius = 14 }, .overflow_hidden = true });
    modal.body.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .gap = 0, .padding = .{} });
    state.header = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 60 }, .direction = .row, .padding = .{ .left = 20, .right = 20, .top = 16, .bottom = 10 }, .align_items = .center, .flex_shrink = 0 }, .{});
    state.title = try ui.textStyled(cx, S.title, "");
    try state.header.appendChild(cx.allocator, state.title);
    try modal.body.appendChild(cx.allocator, state.header);
    const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(bound.scope, cx);
    state.viewport = scroll.container;
    scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 });
    scroll.content.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = .{ .left = 20, .right = 20, .top = 8, .bottom = 18 } });
    state.message = try ui.text(cx, "", .{ .font_size = 12, .line_height = 20.0 / 12.0, .color = S.theme.current().fg_2, .wrap = .word });
    state.message.style.width = .fill();
    try scroll.content.appendChild(cx.allocator, state.message);
    try modal.body.appendChild(cx.allocator, scroll.container);
    state.footer = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 60 }, .direction = .row, .padding = .{ .left = 20, .right = 20, .top = 12, .bottom = 16 }, .flex_shrink = 0 }, .{});
    try state.footer.appendChild(cx.allocator, try ui.spacer(cx));
    state.close_button = try ui.widgets.Button(.{ .label = "关闭", .variant = .secondary, .base_style = S.actionControl(false), .on_click = cx.on(Info, state, Info.close) }).mount(bound.scope, cx);
    try state.footer.appendChild(cx.allocator, state.close_button);
    try modal.body.appendChild(cx.allocator, state.footer);
    if (!modal.portaled) try root.appendChild(cx.allocator, modal.overlay);
    return state;
}
fn infoButton(cx: *ui.Cx, bound: *binding.Binding, details: *Info, entry: registry.PluginManifest, suffix: []const u8, label: []const u8, title: []const u8, message: []const u8, icon_only: bool) !*ui.Node {
    const state = try bound.scope.allocator.create(InfoAction);
    state.* = .{ .scope = bound.scope, .info = details, .title = title, .message = message, .ids = undefined };
    try bound.scope.onCleanup(InfoAction, state, InfoAction.cleanup);
    for ([_][]const u8{ "overlay", "dialog", "header", "message", "viewport", "footer", "close" }, 0..) |part, i| {
        var buffer: [80]u8 = undefined;
        state.ids[i] = try pluginId(bound.scope, entry.id, try std.fmt.bufPrint(&buffer, "{s}.{s}", .{ suffix, part }));
    }
    var style = if (icon_only) S.button(30, false) else S.textButton();
    style.background = ui.Color.TRANSPARENT;
    style.text_color = if (icon_only) S.theme.current().fg_2 else S.theme.current().accent;
    style.font_size = 11;
    const button = try ui.widgets.Button(.{ .label = label, .icon_asset = if (icon_only) ui.icons.info else null, .icon_only = icon_only, .icon_size = @as(f32, 16), .variant = .ghost, .a11y_label = title, .base_style = style, .hover_style = S.buttonHover(), .on_click = cx.on(InfoAction, state, InfoAction.show) }).mount(bound.scope, cx);
    button.meta.ownership.meta.test_id = try pluginId(bound.scope, entry.id, suffix);
    return button;
}

fn futureRow(cx: *ui.Cx, bound: *binding.Binding, name: []const u8, description_text: []const u8, icon: ui.SvgAsset) !*ui.Node {
    const row = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 66 }, .direction = .row, .align_items = .center, .gap = 10, .flex_shrink = 0, .min_width = 0 }, .{});
    try row.appendChild(cx.allocator, try ui.iconTint(cx, icon, S.theme.current().accent, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 }));
    const labels = try ui.box(cx, .{ .width = .fill(), .flex = 1, .min_width = 0, .direction = .column, .gap = 3 }, .{});
    try labels.appendChild(cx.allocator, try ui.text(cx, name, .{ .font_size = 12, .font_weight = 500, .line_height = 1.5, .color = S.theme.current().fg_1 }));
    const detail = try ui.text(cx, description_text, .{ .font_size = 11, .line_height = 18.0 / 11.0, .color = S.theme.current().fg_2, .wrap = .word });
    detail.style.width = .fill();
    try labels.appendChild(cx.allocator, detail);
    try row.appendChild(cx.allocator, labels);
    const tag = try ui.widgets.Tag(.{ .label = "暂不可用", .color = .neutral, .size = .sm }).mount(bound.scope, cx);
    tag.setStyleInline(cx.allocator, .{ .height = .{ .px = 22 }, .padding = .{ .left = 6, .right = 6, .top = 3, .bottom = 3 }, .background = S.theme.current().hover, .border = .{ .radius = 5 }, .flex_shrink = 0 });
    try row.appendChild(cx.allocator, tag);
    return row;
}
