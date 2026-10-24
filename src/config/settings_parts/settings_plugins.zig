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
fn card(cx: *ui.Cx, bound: *binding.Binding, title: []const u8, _: []const u8, icon: ui.SvgAsset, bit: u6, initially_open: bool) !Card {
    const fold = try cx.allocator.create(Fold);
    fold.* = .{ .bound = bound, .bit = bit, .positive = initially_open };
    try bound.scope.onCleanup(Fold, fold, Fold.cleanup);
    const stored = (bound.controller.folded_sections & (@as(u64, 1) << bit)) != 0;
    const open = if (bound.controller.search_query.len != 0) true else if (initially_open) stored else !stored;
    const result = try ui.widgets.AccordionItem(.{ .title = title, .expanded = open, .on_change = ui.Handler(bool).from(Fold, fold, Fold.change), .variant = .ghost }).mount(bound.scope, cx);
    _ = try controls.sectionHeader(cx, bound.scope, result, icon, open, "", title);
    const header = result.header;
    header.meta.ownership.meta.test_id = title;
    if (bound.controller.state() == .saving) {
        header.behavior.events.on_event = null;
        header.behavior.interaction.focusable = false;
    }
    result.body.style.padding = .ZERO;
    result.body.style.width = .fill();
    result.body.style.direction = .column;
    result.body.style.gap = S.geometry.section_gap;
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
    var matched: usize = 0;
    for ([_]registry.Origin{ .builtin, .bundled }, 0..) |origin, group_index| {
        var count: usize = 0;
        for (source.manifests()) |entry| if (entry.origin == origin) {
            count += 1;
        };
        if (count == 0) continue;
        const title: []const u8 = if (origin == .builtin) "已内置" else "随应用提供";
        const section = try card(cx, bound, title, "", ui.icons.plug, @intCast(40 + group_index), group_index == 0);
        var group_matches: usize = 0;
        for (source.manifests()) |entry| {
            if (entry.origin != origin) continue;
            if (!binding.matches(bound.controller.search_query, entry.display_name) and !binding.matches(bound.controller.search_query, title)) continue;
            group_matches += 1;
            try section.body.appendChild(cx.allocator, try pluginRow(cx, bound, entry));
            if (entry.settings_section) |preferences| for (preferences.fields) |field| {
                try section.body.appendChild(cx.allocator, try preferenceRow(cx, bound, entry.id, field));
            };
        }
        matched += group_matches;
        if (group_matches != 0 or bound.controller.search_query.len == 0) try root.appendChild(cx.allocator, section.root) else cx.destroyDetached(section.root);
    }
    if (matched == 0) try root.appendChild(cx.allocator, try ui.textStyled(cx, S.note, if (bound.controller.search_query.len == 0) "没有已注册的插件" else "没有匹配的设置"));
}
fn pluginRow(cx: *ui.Cx, bound: *binding.Binding, entry: registry.PluginManifest) !*ui.Node {
    const row = try ui.boxStyled(cx, S.row, .{});
    row.style.height = .{ .px = S.geometry.builtin_row_height };
    row.meta.ownership.meta.test_id = entry.id;
    const icon = @import("../../ui/session_icon.zig").asset(entry.icons.settings);
    try row.appendChild(cx.allocator, try ui.iconTint(cx, icon, S.theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }));
    const name = try ui.textStyled(cx, S.label, entry.display_name);
    name.style.width = .{ .fit = .{} };
    name.style.flex_shrink = 1;
    name.setStyleInline(cx.allocator, .{ .min_width = 0 });
    try row.appendChild(cx.allocator, name);
    const origin: []const u8 = if (entry.origin == .builtin) "内置" else "随应用提供";
    const tag = try ui.widgets.Tag(.{ .label = origin, .color = .neutral, .size = .sm }).mount(bound.scope, cx);
    tag.setStyleInline(cx.allocator, S.pluginTag(undefined));
    if (tag.children.items.len != 0) {
        const label = tag.children.items[0];
        if (label.getText()) |old| {
            var text = old;
            const style = S.pluginTagLabel(undefined);
            text.font_size = style.font_size;
            text.font_weight = style.font_weight;
            text.line_height = style.line_height;
            text.color = style.color;
            label.setText(text);
        }
    }
    try row.appendChild(cx.allocator, tag);
    try row.appendChild(cx.allocator, try ui.spacer(cx));
    var buffer: [256]u8 = undefined;
    const version = try std.fmt.bufPrint(&buffer, "{s} · {s}\n{s}", .{ entry.display_name, entry.plugin_version, if (entry.session_factory != null) @as([]const u8, "可用") else "运行适配器尚未接入" });
    try row.appendChild(cx.allocator, try infoButton(cx, bound, ui.icons.info, version, "settings.plugin.version", false));
    try row.appendChild(cx.allocator, try infoButton(cx, bound, ui.icons.shield, "连接时按需请求权限", "settings.plugin.permissions", false));
    try row.appendChild(cx.allocator, try infoButton(cx, bound, ui.icons.lock_keyhole, "静态链接插件随应用管理", "settings.plugin.builtin.readonly", true));
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

fn infoButton(cx: *ui.Cx, bound: *binding.Binding, icon: ui.SvgAsset, label: []const u8, id: []const u8, disabled: bool) !*ui.Node {
    const owned = try bound.scope.allocator.create(InfoLabel);
    var adopted = false;
    errdefer if (!adopted) bound.scope.allocator.destroy(owned);
    owned.* = .{ .allocator = bound.scope.allocator, .text = try bound.scope.allocator.dupe(u8, label) };
    errdefer if (!adopted) bound.scope.allocator.free(owned.text);
    try bound.scope.onCleanup(InfoLabel, owned, InfoLabel.cleanup);
    adopted = true;
    const tooltip = try ui.widgets.Tooltip(.{ .text = owned.text, .open_delay_ms = 450 }).mount(bound.scope, cx);
    var style = S.button(S.geometry.icon_button, false);
    if (!disabled) style.background = ui.Color.TRANSPARENT;
    const button = try ui.widgets.Button(.{ .icon_asset = icon, .icon_only = true, .icon_size = @as(f32, 16), .variant = .ghost, .a11y_label = owned.text, .disabled = disabled, .base_style = style, .hover_style = S.buttonHover() }).mount(bound.scope, cx);
    button.meta.ownership.meta.test_id = id;
    try tooltip.trigger.appendChild(cx.allocator, button);
    return tooltip.wrapper;
}
const InfoLabel = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    fn cleanup(self: *InfoLabel) void {
        self.allocator.free(self.text);
        self.allocator.destroy(self);
    }
};
