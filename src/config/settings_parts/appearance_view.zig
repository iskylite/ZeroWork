const std = @import("std");
const ui = @import("ui");
const binding = @import("../settings_content_view.zig");
const Context = @import("../appearance_ui_context.zig").Context;
const themes = @import("../theme_registry.zig");
const values = @import("../settings_values.zig");
const schema = @import("../settings_schema.zig");
const S = @import("appearance_styles.zig");
const controls = @import("settings_controls.zig");

fn disabled(bound: *binding.Binding) bool {
    return bound.controller.state() == .saving or if (bound.hooks.appearance) |host| host.isBusy() else false;
}
fn changed(bound: *binding.Binding) void {
    bound.refreshFooter();
    bound.hooks.changed(bound.hooks.context);
}
fn owned(scope: *ui.Scope, text: []const u8) ![]const u8 {
    const Text = struct {
        allocator: std.mem.Allocator,
        value: []u8,
        fn release(self: *@This()) void {
            self.allocator.free(self.value);
            self.allocator.destroy(self);
        }
    };
    const holder = try scope.allocator.create(Text);
    errdefer scope.allocator.destroy(holder);
    holder.* = .{ .allocator = scope.allocator, .value = try scope.allocator.dupe(u8, text) };
    errdefer scope.allocator.free(holder.value);
    try scope.onCleanup(Text, holder, Text.release);
    return holder.value;
}
fn id(scope: *ui.Scope, prefix: []const u8, suffix: []const u8) ![]const u8 {
    const text = try std.fmt.allocPrint(scope.allocator, "{s}{s}", .{ prefix, suffix });
    defer scope.allocator.free(text);
    return owned(scope, text);
}
fn icon(cx: *ui.Cx, asset: ui.SvgAsset, color: ui.Color) !*ui.Node {
    return ui.iconTint(cx, asset, color, .{ .width = .{ .px = S.g.icon }, .height = .{ .px = S.g.icon } });
}
fn textFill(node: *ui.Node) void {
    node.style.width = .fill();
    node.style.flex = 1;
}

const Card = struct { root: *ui.Node, body: *ui.Node, header: *ui.Node };
fn card(cx: *ui.Cx, bound: *binding.Binding, title: []const u8, summary: []const u8, asset: ui.SvgAsset, bit: u6, test_id: []const u8) !Card {
    const fold = try bound.scope.allocator.create(Fold);
    fold.* = .{ .bound = bound, .bit = bit };
    try bound.scope.onCleanup(Fold, fold, Fold.cleanup);
    const expanded = bound.controller.search_query.len != 0 or bound.controller.folded_sections & (@as(u64, 1) << bit) == 0;
    const result = try ui.widgets.AccordionItem(.{ .title = title, .expanded = expanded, .variant = .ghost, .on_change = cx.on(Fold, fold, Fold.change) }).mount(bound.scope, cx);
    _ = try controls.sectionHeader(cx, bound.scope, result, asset, expanded, summary, test_id);
    result.item.meta.ownership.meta.test_id = test_id;
    result.header.meta.ownership.meta.test_id = try id(bound.scope, test_id, ".header");
    if (disabled(bound) or bound.controller.search_query.len != 0) {
        result.header.behavior.events.on_event = null;
        result.header.setFocusable(false);
    }
    result.body.setStyleInline(cx.allocator, S.column(undefined));
    result.body.style.padding = .{ .left = 16, .right = 16, .bottom = 8 };
    result.body.style.gap = 0;
    return .{ .root = result.item, .body = result.body, .header = result.header };
}
const Fold = struct {
    bound: *binding.Binding,
    bit: u6,
    fn cleanup(self: *Fold) void {
        self.bound.scope.allocator.destroy(self);
    }
    fn change(self: *Fold, open: bool) void {
        if (disabled(self.bound) or self.bound.controller.search_query.len != 0) return;
        const mask = @as(u64, 1) << self.bit;
        if (open) self.bound.controller.folded_sections &= ~mask else self.bound.controller.folded_sections |= mask;
        changed(self.bound);
    }
};

const Click = struct {
    bound: *binding.Binding,
    scope: *ui.Scope,
    kind: Kind,
    text: []const u8 = "",
    key: binding.Key = .{ .section = "ui", .key = "theme" },
    close: ?ui.Handler(void) = null,
    const Kind = enum { open_library, close_library, select_theme, favorite, remove_theme, import_theme, choose_image, remove_image, toggle, choice, custom_font, preview_material, return_material, restore_material };
    fn create(scope: *ui.Scope, bound: *binding.Binding, kind: Kind, text: []const u8) !*Click {
        const self = try scope.allocator.create(Click);
        self.* = .{ .bound = bound, .scope = scope, .kind = kind, .text = try owned(scope, text) };
        try scope.onCleanup(Click, self, cleanup);
        return self;
    }
    fn cleanup(self: *Click) void {
        self.scope.allocator.destroy(self);
    }
    fn activate(self: *Click) void {
        const bound = self.bound;
        const c = bound.controller;
        const host = bound.hooks.appearance;
        if (disabled(bound) and self.kind != .close_library and self.kind != .return_material) return;
        if (self.close) |close| close.invoke();
        switch (self.kind) {
            .open_library => {
                c.theme_library.open = true;
                if (host) |h| h.library_dismissed = false;
                changed(bound);
            },
            .close_library => {
                c.theme_library.open = false;
                if (host) |h| h.library_dismissed = true;
                changed(bound);
            },
            .select_theme => {
                const h = host orelse return;
                c.selectTheme(h.registry, self.text) catch return;
                changed(bound);
            },
            .favorite => {
                const h = host orelse return;
                const record = h.registry.get(self.text) orelse return;
                h.send(.{ .favorite = .{ .id = record.id, .registry_revision = h.registry.revision, .enabled = !record.favorite } });
            },
            .remove_theme => {
                const h = host orelse return;
                h.send(.{ .remove_theme = .{ .id = self.text, .registry_revision = h.registry.revision } });
            },
            .import_theme => {
                const h = host orelse return;
                const request = c.requestThemeImport() catch return;
                h.send(.{ .pick_theme = request });
            },
            .choose_image => {
                const h = host orelse return;
                h.send(.{ .pick_background = .{ .draft_id = c.draft_id, .asset_revision = c.background.asset_revision } });
            },
            .remove_image => {
                c.editKey("ui.materials.background", "path", .{ .text = "" }) catch return;
                bound.valuesChanged();
                changed(bound);
            },
            .toggle => {
                const current = values.read(c.model.value, self.key.section, self.key.key) orelse return;
                if (current != .boolean) return;
                c.editKey(self.key.section, self.key.key, .{ .boolean = !current.boolean }) catch return;
                bound.valuesChanged();
                changed(bound);
            },
            .choice => {
                c.editKey(self.key.section, self.key.key, .{ .text = self.text }) catch return;
                if (host) |h| if (std.mem.eql(u8, self.key.section, "ui") and (std.mem.eql(u8, self.key.key, "font_family") or std.mem.eql(u8, self.key.key, "font_weight"))) h.send(.validate_font);
                bound.valuesChanged();
                changed(bound);
            },
            .custom_font => {
                const h = host orelse return;
                h.custom_font_edit = true;
                h.focus_custom_font = true;
                changed(bound);
            },
            .preview_material => if (host) |h| h.send(.{ .preview_material = true }),
            .return_material => if (host) |h| h.send(.{ .preview_material = false }),
            .restore_material => if (host) |h| h.send(.restore_materials),
        }
    }
};
fn iconButton(cx: *ui.Cx, scope: *ui.Scope, bound: *binding.Binding, kind: Click.Kind, stable_id: []const u8, asset: ui.SvgAsset, label: []const u8, test_id: []const u8, size: f32, is_disabled: bool) !*ui.Node {
    const click = try Click.create(scope, bound, kind, stable_id);
    const tip = try ui.widgets.Tooltip(.{ .text = label, .open_delay_ms = 450 }).mount(scope, cx);
    const favorite = if (kind == .favorite) if (bound.hooks.appearance) |h| if (h.registry.get(stable_id)) |record| record.favorite else false else false else false;
    const button = try ui.widgets.Button(.{ .a11y_label = label, .icon_only = true, .icon_asset = asset, .icon_size = @as(f32, 16), .icon_tint = if (favorite) S.theme.current().accent_ink else S.theme.current().fg_2, .variant = .ghost, .disabled = is_disabled, .on_click = cx.on(Click, click, Click.activate), .base_style = S.plainButton(size, size, favorite), .hover_style = S.base.buttonHover() }).mount(scope, cx);
    button.meta.ownership.meta.test_id = test_id;
    try tip.trigger.appendChild(cx.allocator, button);
    return tip.wrapper;
}
fn textAction(cx: *ui.Cx, bound: *binding.Binding, kind: Click.Kind, stable_id: []const u8, label: []const u8, tooltip: []const u8, test_id: []const u8, danger: bool, is_disabled: bool) !*ui.Node {
    const action = try Click.create(bound.scope, bound, kind, stable_id);
    const tip = try ui.widgets.Tooltip(.{ .text = tooltip, .open_delay_ms = 450 }).mount(bound.scope, cx);
    const button = try ui.widgets.Button(.{ .label = label, .variant = .ghost, .disabled = is_disabled, .on_click = cx.on(Click, action, Click.activate), .base_style = .{ .height = .{ .px = 28 }, .padding = .{ .top = 5, .bottom = 5 }, .font_size = 11, .font_weight = 400, .text_color = if (danger) S.theme.current().danger_ink else S.theme.current().accent_ink }, .hover_style = S.base.buttonHover() }).mount(bound.scope, cx);
    button.meta.ownership.meta.test_id = test_id;
    try tip.trigger.appendChild(cx.allocator, button);
    return tip.wrapper;
}
fn thumbnail(cx: *ui.Cx, record: *const themes.Record) !*ui.Node {
    const root = try ui.box(cx, S.thumbnail(rgba(record.theme.bg)), .{});
    for ([_]u32{ record.ui_tokens.accent, record.theme.ansi[2], record.theme.ansi[4], record.theme.ansi[1] }) |color| try root.appendChild(cx.allocator, try ui.box(cx, .{ .width = .{ .px = 4 }, .height = .{ .px = 16 }, .background = rgba(color), .border = .{ .radius = 1 }, .flex_shrink = 0 }, .{}));
    return root;
}
fn rgba(value: u32) ui.Color {
    return ui.Color.rgba(@intCast(value >> 24), @intCast((value >> 16) & 255), @intCast((value >> 8) & 255), @intCast(value & 255));
}

pub fn mountContent(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const root = try ui.boxStyled(cx, S.base.sectionColumn, .{});
    root.meta.ownership.meta.test_id = "settings.appearance";
    const query = bound.controller.search_query;
    if (query.len == 0 or binding.matches(query, "应用图标 透明背景 黑底 白底 Dock icon_background")) try root.appendChild(cx.allocator, try appIconSection(cx, bound));
    if (query.len == 0 or binding.matches(query, "外观 主题 theme 主题库")) try root.appendChild(cx.allocator, try themeSection(cx, bound));
    if (query.len == 0 or binding.matches(query, "背景 图片 材质 模糊 透明度 fit 对齐 blur_px background enabled path alignment_x alignment_y transparency")) try root.appendChild(cx.allocator, try materialSection(cx, bound));
    if (query.len == 0 or binding.matches(query, "字体 字号 行高 光标 font cursor font_family font_size font_weight line_height cursor_style")) try root.appendChild(cx.allocator, try fontSection(cx, bound));
    if (query.len == 0 or binding.matches(query, "终端 工作区 最大显示行数 回滚 scrollback_limit 时间戳 侧栏 高亮 补全 timestamp_gutter sidebar_collapsed input_line_highlight completion enabled")) try root.appendChild(cx.allocator, try aidsSection(cx, bound));
    if (root.children.items.len == 0) try root.appendChild(cx.allocator, try ui.textStyled(cx, S.note, "没有匹配的设置"));
    return root;
}

fn themeSection(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const host = bound.hooks.appearance;
    const c = bound.controller;
    const record = if (host) |h| h.registry.get(c.model.value.ui.theme) else null;
    const selected_name = if (record) |r| r.theme.name else c.model.value.ui.theme;
    const section = try card(cx, bound, "主题", selected_name, ui.icons.palette, 0, "settings.appearance.themes");
    const row = try ui.boxStyled(cx, S.materialRow, .{});
    row.setStyleInline(cx.allocator, .{ .height = .{ .px = 30 }, .min_height = 30, .padding = .{ .top = 4 } });
    row.style.gap = 8;
    row.meta.ownership.meta.test_id = "settings.theme.current";
    var count_buffer: [64]u8 = undefined;
    const name = try ui.textStyled(cx, S.note, if (host) |h| try std.fmt.bufPrint(&count_buffer, "{d} 个主题 · 左右滚动浏览", .{h.registry.counts().all}) else selected_name);
    textFill(name);
    try row.appendChild(cx.allocator, name);
    if (!std.mem.eql(u8, c.model.value.ui.theme, c.original.value.ui.theme)) try row.appendChild(cx.allocator, try previewBadge(cx, "预览中"));
    var remove_reason: []const u8 = "删除当前主题";
    const protected = blk: {
        const h = host orelse break :blk true;
        h.registry.checkRemove(c.model.value.ui.theme, h.registry.revision, .{ .saved = h.runtime.value.ui.theme, .draft = c.model.value.ui.theme }) catch |err| {
            remove_reason = themeProblem(err);
            break :blk true;
        };
        break :blk false;
    };
    const current_builtin = if (record) |current_record| current_record.source_kind == .builtin else false;
    try row.appendChild(cx.allocator, try textAction(cx, bound, .remove_theme, c.model.value.ui.theme, if (current_builtin) "内置主题不可删除" else "删除当前主题", remove_reason, "settings.theme.remove.current", !current_builtin, protected or disabled(bound)));
    try row.appendChild(cx.allocator, try textAction(cx, bound, .import_theme, "", "导入 .itermcolors", "仅支持 iTerm2 .itermcolors 主题文件", "settings.theme.import", false, host == null or disabled(bound)));
    if (host) |h| try section.body.appendChild(cx.allocator, try themeStrip(cx, bound, h));
    try section.body.appendChild(cx.allocator, row);
    if (c.theme_library.problem) |problem| try section.body.appendChild(cx.allocator, try notice(cx, themeProblem(problem), true));
    return section.root;
}

/// V3 keeps all theme choices in the card; legacy library state cannot replace it.
fn themeStrip(cx: *ui.Cx, bound: *binding.Binding, host: *Context) !*ui.Node {
    const scroll = try ui.widgets.ScrollArea(.{ .direction = .horizontal, .rubber_band_x = false }).mount(bound.scope, cx);
    scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 75 }, .min_width = 0, .flex_shrink = 0 });
    scroll.container.meta.ownership.meta.test_id = "settings.theme.strip";
    scroll.content.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .height = .{ .px = 75 }, .direction = .row, .gap = 8 });
    var selected_index: usize = 0;
    for (host.registry.records.items, 0..) |*record, record_index| {
        const selected = std.mem.eql(u8, bound.controller.model.value.ui.theme, record.id);
        if (selected) selected_index = record_index;
        const choose = try Click.create(bound.scope, bound, .select_theme, record.id);
        const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = record.theme.name, .disabled = disabled(bound), .on_click = cx.on(Click, choose, Click.activate), .base_style = .{ .width = .{ .px = 150 }, .height = .{ .px = 75 }, .padding = ui.Padding.all(6), .background = if (selected) S.theme.current().selection else S.theme.current().well, .corner_radius = 9, .border_width = 0 }, .hover_style = S.base.buttonHover() }).mount(bound.scope, cx);
        button.setStyleInline(cx.allocator, .{ .direction = .column, .align_items = .stretch, .justify = .start, .gap = 5, .flex_shrink = 0 });
        button.meta.ownership.meta.test_id = try id(bound.scope, "settings.theme.", record.id);
        if (button.behavior.interaction.a11y) |*access| {
            access.selected = selected;
            access.pressed = selected;
        }
        const preview = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 6 }, .top = .{ .px = 6 } }, .width = .{ .px = 138 }, .height = .{ .px = 42 }, .direction = .row, .padding = ui.Padding.all(6), .gap = 5, .background = rgba(record.theme.bg), .border = .{ .radius = 6 }, .flex_shrink = 0 }, .{});
        try preview.appendChild(cx.allocator, try ui.box(cx, .{ .width = .{ .px = 20 }, .height = .fill(), .background = rgba(record.ui_tokens.surface_2), .border = .{ .radius = 4 } }, .{}));
        const lines = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .gap = 4 }, .{});
        for ([_]f32{ 70, 90, 48 }, [_]ui.Color{ rgba(record.ui_tokens.accent), rgba(record.theme.ansi[2]), rgba(record.theme.fg).withAlpha(110) }) |width, color| try lines.appendChild(cx.allocator, try ui.box(cx, .{ .width = .{ .percent = width }, .height = .{ .px = 4 }, .background = color, .border = .{ .radius = 1.5 } }, .{}));
        try preview.appendChild(cx.allocator, lines);
        try button.appendChild(cx.allocator, preview);
        const caption = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 6 }, .top = .{ .px = 53 } }, .width = .{ .px = 138 }, .height = .{ .px = 16 }, .direction = .row, .align_items = .center, .gap = 4 }, .{});
        const name = try ui.text(cx, record.theme.name, .{ .font_size = 11, .font_weight = 500, .color = S.theme.current().fg_1, .text_overflow = .ellipsis, .selectable = false });
        name.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0, .overflow_hidden = true });
        try caption.appendChild(cx.allocator, name);
        if (selected) try caption.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.check, S.theme.current().accent_ink, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 } }));
        try button.appendChild(cx.allocator, caption);
        if (record.source_kind == .imported) {
            var reason: []const u8 = "删除导入主题";
            const protected = blk: {
                host.registry.checkRemove(record.id, host.registry.revision, .{ .saved = host.runtime.value.ui.theme, .draft = bound.controller.model.value.ui.theme }) catch |err| {
                    reason = switch (err) {
                        error.CurrentThemeProtected => "使用中 · 请先切换并保存",
                        error.DraftThemeProtected => "预览中 · 请先切换待选主题",
                        else => themeProblem(err),
                    };
                    break :blk true;
                };
                break :blk false;
            };
            const remove = try Click.create(bound.scope, bound, .remove_theme, record.id);
            const open = try bound.scope.createSignal(bool, false);
            const menu = try ui.widgets.Menu(.{
                .trigger = .manual,
                .open = open,
                .width = @as(f32, 210),
                .items = &[_]ui.widgets.MenuItem{.{ .id = "remove", .label = reason, .icon_asset = ui.icons.trash, .danger = true, .disabled = protected or disabled(bound), .on_click = cx.on(Click, remove, Click.activate) }},
            }).mount(bound.scope, cx);
            menu.wrapper.setStyleInline(cx.allocator, .{ .width = .{ .px = 150 }, .height = .{ .px = 75 }, .flex_shrink = 0 });
            menu.wrapper.meta.ownership.meta.test_id = try id(bound.scope, "settings.theme.menu.", record.id);
            const trigger = try bound.scope.allocator.create(ThemeContextMenu);
            trigger.* = .{ .scope = bound.scope, .open = open };
            try bound.scope.onCleanup(ThemeContextMenu, trigger, ThemeContextMenu.cleanup);
            if (button.behavior.interaction.a11y) |*access| access.has_popup = .menu;
            button.behavior.events.on_event_capture = ThemeContextMenu.event;
            button.behavior.events.capture_context = trigger;
            try menu.trigger.appendChild(cx.allocator, button);
            try scroll.content.appendChild(cx.allocator, menu.wrapper);
        } else try scroll.content.appendChild(cx.allocator, button);
    }
    const reveal = try bound.scope.allocator.create(ThemeStripSelection);
    reveal.* = .{ .cx = cx, .scope = bound.scope, .scroll = scroll, .selected_index = selected_index, .count = host.registry.records.items.len };
    try bound.scope.onCleanup(ThemeStripSelection, reveal, ThemeStripSelection.cleanup);
    try cx.addAfterLayoutHook(reveal, ThemeStripSelection.afterLayout);
    return scroll.container;
}

/// Restore the selected card once after a page remount. Subsequent user scroll
/// gestures remain in control; this hook never snaps a live strip back.
const ThemeContextMenu = struct {
    scope: *ui.Scope,
    open: *ui.Signal(bool),
    fn cleanup(self: *ThemeContextMenu) void {
        self.scope.allocator.destroy(self);
    }
    fn event(e: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
        const self: *ThemeContextMenu = @ptrCast(@alignCast(context orelse return .ignored));
        if (e == .mouse_down and e.mouse_down.button == .right) {
            self.open.set(true);
            return .stop;
        }
        if (e == .key_down and e.key_down.key == .f10 and e.key_down.modifiers.shift and !e.key_down.modifiers.ctrl and !e.key_down.modifiers.alt and !e.key_down.modifiers.super) {
            self.open.set(true);
            return .stop;
        }
        return .ignored;
    }
};

const ThemeStripSelection = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    scroll: ui.widgets.scroll_area.ScrollAreaResult,
    selected_index: usize,
    count: usize,
    pending: bool = true,
    fn cleanup(self: *ThemeStripSelection) void {
        self.cx.removeAfterLayoutHook(self);
        self.scope.allocator.destroy(self);
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *ThemeStripSelection = @ptrCast(@alignCast(raw));
        if (!self.pending) return .done;
        const width = self.scroll.container.globalRect().w;
        if (width <= 0) return .done;
        self.pending = false;
        const selected_right = @as(f32, @floatFromInt(self.selected_index)) * 158 + 150;
        const content_width = @as(f32, @floatFromInt(self.count)) * 158 - 8;
        self.scroll.state.scroll_x = std.math.clamp(selected_right - width, 0, @max(0, content_width - width));
        self.scroll.content.setStyle(self.cx.allocator, .translate_x, self.scroll.state.contentTranslateX());
        return .done;
    }
};

fn previewBadge(cx: *ui.Cx, label: []const u8) !*ui.Node {
    return ui.boxStyled(cx, S.previewBadge, .{try ui.text(cx, label, .{ .font_size = 10.5, .font_weight = 500, .line_height = 15.0 / 10.5, .color = S.theme.current().accent_ink })});
}
fn dismissedTheme(cx: *ui.Cx, bound: *binding.Binding, host: *Context) !*ui.Node {
    const root = try ui.boxStyled(cx, S.column, .{});
    const row = try ui.boxStyled(cx, S.dismissedTheme, .{});
    row.meta.ownership.meta.test_id = "settings.theme.dismissed";
    const c = bound.controller;
    const record = host.registry.get(c.model.value.ui.theme) orelse return root;
    try row.appendChild(cx.allocator, try thumbnail(cx, record));
    const title = try ui.textStyled(cx, S.label, record.theme.name);
    textFill(title);
    try row.appendChild(cx.allocator, title);
    if (!std.mem.eql(u8, c.model.value.ui.theme, c.original.value.ui.theme)) try row.appendChild(cx.allocator, try previewBadge(cx, "预览中"));
    try row.appendChild(cx.allocator, try iconButton(cx, bound.scope, bound, .open_library, "", ui.icons.palette, "重新打开主题库，保留选择与查询", "settings.theme.library.open", 28, disabled(bound)));
    try root.appendChild(cx.allocator, row);
    const preview = try card(cx, bound, "主题预览", record.theme.name, ui.icons.palette, 0, "settings.theme.preview");
    try preview.body.appendChild(cx.allocator, try miniPreview(cx, record, c.model.value.ui.timestamp_gutter, c.model.value.ui.input_line_highlight, c.model.value.ui.sidebar_collapsed));
    try root.appendChild(cx.allocator, preview.root);
    return root;
}

fn themeProblem(problem: anyerror) []const u8 {
    return switch (problem) {
        error.MissingColors => "导入失败 · 缺少 ANSI 0–15 或必要颜色",
        error.ThemeTooLarge, error.StreamTooLong => "导入失败 · 文件超过 2 MiB",
        error.InvalidPlist, error.InvalidComponent => "导入失败 · 主题格式或颜色无效",
        error.BuiltinThemeProtected => "内置主题不可删除",
        error.CurrentThemeProtected => "先选择其他主题并保存，再移除此主题",
        error.DraftThemeProtected => "先切换待选主题，再移除此主题",
        error.FileNotFound => "文件已移动或不存在，原草稿已保留",
        error.AccessDenied => "权限不足，原草稿已保留",
        else => @errorName(problem),
    };
}
fn notice(cx: *ui.Cx, message: []const u8, is_error: bool) !*ui.Node {
    const row = try ui.boxStyled(cx, S.notice, .{});
    try row.appendChild(cx.allocator, try icon(cx, if (is_error) ui.icons.circle_alert else ui.icons.info, if (is_error) S.theme.current().danger_ink else S.theme.current().fg_2));
    const text = if (is_error) try ui.textStyled(cx, S.errorNote, message) else try ui.textStyled(cx, S.note, message);
    textFill(text);
    try row.appendChild(cx.allocator, text);
    return row;
}

fn miniPreview(cx: *ui.Cx, record: *const themes.Record, timestamps: bool, highlight: bool, collapsed: bool) !*ui.Node {
    const p = record.ui_tokens;
    const root = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 80 }, .background = rgba(p.app), .border = .{ .radius = 9 }, .direction = .column, .gap = 6, .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 }, .flex_shrink = 0 }, .{});
    root.meta.ownership.meta.test_id = "settings.appearance.mini_preview";
    const top = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 16 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 }, .{});
    try top.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.terminal, rgba(p.fg_2), .{ .width = .{ .px = 12 }, .height = .{ .px = 12 } }));
    try top.appendChild(cx.allocator, try ui.text(cx, "ZeroWork", .{ .font_size = 10, .line_height = 1.4, .color = rgba(p.fg_2) }));
    try top.appendChild(cx.allocator, try ui.spacer(cx));
    try top.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.settings, rgba(p.fg_2), .{ .width = .{ .px = 12 }, .height = .{ .px = 12 } }));
    try root.appendChild(cx.allocator, top);
    const body = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 42 }, .direction = .row, .gap = 6, .flex_shrink = 0 }, .{});
    if (!collapsed) {
        const sidebar = try ui.box(cx, .{ .width = .{ .px = 48 }, .height = .fill(), .padding = .{ .left = 8, .top = 7 }, .background = rgba(p.surface_1), .border = .{ .radius = 5 }, .flex_shrink = 0 }, .{});
        try sidebar.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.server, rgba(p.accent), .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } }));
        try body.appendChild(cx.allocator, sidebar);
    }
    const terminal = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .background = rgba(record.theme.bg), .padding = .{ .left = 5.6, .right = 5.6, .top = 5.6, .bottom = 5.6 }, .border = .{ .radius = 5 } }, .{});
    for ([_][]const u8{ "api   Running", "$ ssh prod-01" }, 0..) |line, i| {
        const row = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 15.4 }, .direction = .row, .align_items = .center, .gap = 6, .background = if (highlight and i == 1) rgba(p.selection) else ui.Color.TRANSPARENT, .flex_shrink = 0 }, .{});
        if (timestamps) try row.appendChild(cx.allocator, try ui.text(cx, if (i == 0) "14:20:01" else "14:20:02", .{ .font_size = 6.65, .line_height = 9.8 / 6.65, .color = rgba(p.fg_3), .use_monospace_font = true }));
        try row.appendChild(cx.allocator, try ui.text(cx, line, .{ .font_size = 9.8, .line_height = 15.4 / 9.8, .color = if (i == 0) rgba(record.theme.ansi[2]) else rgba(record.theme.fg), .use_monospace_font = true }));
        try terminal.appendChild(cx.allocator, row);
    }
    try body.appendChild(cx.allocator, terminal);
    try root.appendChild(cx.allocator, body);
    return root;
}

const ThemeGrid = struct {
    cx: *ui.Cx,
    bound: *binding.Binding,
    host: *Context,
    root: *ui.Node,
    grid: *ui.Node,
    input: ui.widgets.input.InputResult,
    row_scope: ?*ui.Scope = null,
    pending: bool = true,
    last_width: f32 = 0,
    filters: [3]*ui.Node = undefined,
    fn mount(cx: *ui.Cx, bound: *binding.Binding, host: *Context) !*ThemeGrid {
        const self = try bound.scope.allocator.create(ThemeGrid);
        const root = try ui.boxStyled(cx, S.column, .{});
        self.* = .{ .cx = cx, .bound = bound, .host = host, .root = root, .grid = undefined, .input = undefined };
        try bound.scope.onCleanup(ThemeGrid, self, cleanup);
        const categories = try ui.boxStyled(cx, S.materialRow, .{});
        categories.style.height = .{ .px = 28 };
        const counts = host.registry.counts();
        for ([_]themes.Filter{ .all, .favorites, .imported }, [_][]const u8{ "全部", "收藏", "已导入" }, [_]usize{ counts.all, counts.favorites, counts.imported }, 0..) |filter, label, count, i| {
            const choice = try bound.scope.allocator.create(FilterClick);
            choice.* = .{ .grid = self, .filter = filter };
            try bound.scope.onCleanup(FilterClick, choice, FilterClick.cleanup);
            var buffer: [64]u8 = undefined;
            const button = try ui.widgets.Button(.{ .label = try owned(bound.scope, try std.fmt.bufPrint(&buffer, "{s} {d}", .{ label, count })), .variant = .ghost, .on_click = cx.on(FilterClick, choice, FilterClick.activate), .base_style = S.plainButton(110, 28, bound.controller.theme_library.filter == filter), .hover_style = S.base.buttonHover() }).mount(bound.scope, cx);
            button.meta.ownership.meta.test_id = try id(bound.scope, "settings.theme.filter.", @tagName(filter));
            self.filters[i] = button;
            try categories.appendChild(cx.allocator, button);
        }
        try root.appendChild(cx.allocator, categories);
        self.input = try ui.widgets.Input(.{ .value = bound.controller.theme_library.query, .placeholder = "搜索主题…", .append_icon_asset = ui.icons.search, .on_change = cx.on(ThemeGrid, self, queryChanged) }).mountResult(bound.scope, cx);
        self.input.input_container.setStyleInline(cx.allocator, S.field(580, 32));
        self.input.input_container.style.width = .fill();
        S.tuneInput(&self.input);
        self.input.input_container.meta.ownership.meta.test_id = "settings.theme.search";
        try bound.registerInput(self.input.state);
        try root.appendChild(cx.allocator, self.input.node);
        self.grid = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .flex_wrap = .wrap, .gap = 6, .flex_shrink = 0, .min_width = 0 }, .{});
        self.grid.meta.ownership.meta.test_id = "settings.theme.grid";
        try root.appendChild(cx.allocator, self.grid);
        try cx.addAfterLayoutHook(self, afterLayout);
        try self.flush(580);
        return self;
    }
    fn cleanup(self: *ThemeGrid) void {
        self.cx.removeAfterLayoutHook(self);
        self.row_scope = null;
        self.bound.scope.allocator.destroy(self);
    }
    fn queryChanged(self: *ThemeGrid, text: []const u8) void {
        self.bound.controller.theme_library.setQuery(self.bound.controller.allocator, text) catch return;
        self.pending = true;
        self.cx.requestRedraw();
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *ThemeGrid = @ptrCast(@alignCast(raw));
        const width = self.grid.globalRect().w;
        if (width <= 0) return .done;
        if (!self.pending and @abs(width - self.last_width) < 0.5) return .done;
        self.flush(width) catch return .done;
        return .needs_layout;
    }
    fn flush(self: *ThemeGrid, width: f32) !void {
        self.pending = false;
        self.last_width = width;
        if (self.row_scope) |old| old.dispose();
        self.row_scope = null;
        while (self.grid.children.items.len > 0) {
            const old = self.grid.children.items[0];
            self.cx.detachChild(self.grid, old);
            self.cx.destroyDetached(old);
        }
        const scope = try self.bound.scope.childScope();
        self.row_scope = scope;
        const columns: usize = if (width >= 552) 3 else if (width >= 366) 2 else 1;
        const tile_width = @floor((width - 6 * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns)));
        var matches: usize = 0;
        for (self.host.registry.records.items) |*record| {
            if (!themes.Registry.matches(record.*, self.bound.controller.theme_library.filter, self.bound.controller.theme_library.query)) continue;
            matches += 1;
            try self.grid.appendChild(self.cx.allocator, try self.tile(scope, record, tile_width));
        }
        if (matches == 0) {
            const empty = try ui.box(self.cx, .{ .width = .{ .px = width }, .height = .{ .px = 108 }, .padding = .{ .left = 12, .top = 42 }, .background = S.theme.current().well, .border = .{ .radius = 8 } }, .{try ui.textStyled(self.cx, S.label, "没有匹配主题")});
            empty.meta.ownership.meta.test_id = "settings.theme.empty";
            try self.grid.appendChild(self.cx.allocator, empty);
        }
        for (self.filters, [_]themes.Filter{ .all, .favorites, .imported }) |button, filter| button.setBackground(if (self.bound.controller.theme_library.filter == filter) S.theme.current().selection else ui.Color.TRANSPARENT);
    }
    fn tile(self: *ThemeGrid, scope: *ui.Scope, record: *const themes.Record, width: f32) !*ui.Node {
        const cx = self.cx;
        const c = self.bound.controller;
        const wrapper = try ui.box(cx, .{ .width = .{ .px = width }, .height = .{ .px = 56 }, .flex_shrink = 0 }, .{});
        const choose = try Click.create(scope, self.bound, .select_theme, record.id);
        const selected = std.mem.eql(u8, c.model.value.ui.theme, record.id);
        const button = try ui.widgets.Button(.{ .a11y_label = record.theme.name, .variant = .ghost, .disabled = disabled(self.bound), .on_click = cx.on(Click, choose, Click.activate), .base_style = S.tile(width, selected), .hover_style = S.base.buttonHover() }).mount(scope, cx);
        button.setStyleInline(cx.allocator, S.tile(width, selected));
        if (button.behavior.interaction.a11y) |*access| {
            access.selected = selected;
            access.pressed = selected;
        }
        button.meta.ownership.meta.test_id = try id(scope, "settings.theme.", record.id);
        try button.appendChild(cx.allocator, try thumbnail(cx, record));
        const text = try ui.boxStyled(cx, S.column, .{});
        text.style.gap = 5;
        text.style.margin.bottom = 2;
        textFill(text);
        try text.appendChild(cx.allocator, try ui.textStyled(cx, S.tileTitle, record.theme.name));
        const identity = if (std.mem.eql(u8, self.host.runtime.value.ui.theme, record.id)) "使用中" else if (selected) "预览中" else if (record.source_kind == .builtin) "内置" else if (record.staged_for != null) "已导入 · 未保存" else "已导入";
        try text.appendChild(cx.allocator, try ui.textStyled(cx, S.tileIdentity, identity));
        try button.appendChild(cx.allocator, text);
        try wrapper.appendChild(cx.allocator, button);
        const favorite = try iconButton(cx, scope, self.bound, .favorite, record.id, ui.icons.star, if (record.favorite) "取消收藏" else "收藏主题", try id(scope, "settings.theme.favorite.", record.id), 24, disabled(self.bound));
        favorite.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .right = .{ .px = 4 }, .top = .{ .px = 2 } }, .width = .{ .px = 24 }, .height = .{ .px = 24 } });
        try wrapper.appendChild(cx.allocator, favorite);
        var reason: []const u8 = "移除导入主题";
        const protected = blk: {
            self.host.registry.checkRemove(record.id, self.host.registry.revision, .{ .saved = self.host.runtime.value.ui.theme, .draft = c.model.value.ui.theme }) catch |err| {
                reason = themeProblem(err);
                break :blk true;
            };
            break :blk false;
        };
        const remove = try iconButton(cx, scope, self.bound, .remove_theme, record.id, if (record.source_kind == .builtin) ui.icons.lock else ui.icons.trash, reason, try id(scope, "settings.theme.remove.", record.id), 24, protected or disabled(self.bound));
        remove.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .right = .{ .px = 4 }, .top = .{ .px = 30 } }, .width = .{ .px = 24 }, .height = .{ .px = 24 } });
        try wrapper.appendChild(cx.allocator, remove);
        if (selected) {
            const check = try icon(cx, ui.icons.check, S.theme.current().accent_ink);
            check.setStyleInline(cx.allocator, .{ .position = .absolute, .width = .{ .px = 12 }, .height = .{ .px = 12 }, .inset = .{ .right = .{ .px = 31 }, .top = .{ .px = 32 } }, .hit_behavior = .pass_through });
            check.meta.ownership.meta.test_id = try id(scope, "settings.theme.selected.", record.id);
            try wrapper.appendChild(cx.allocator, check);
        }
        return wrapper;
    }
};
const FilterClick = struct {
    grid: *ThemeGrid,
    filter: themes.Filter,
    fn cleanup(self: *FilterClick) void {
        self.grid.bound.scope.allocator.destroy(self);
    }
    fn activate(self: *FilterClick) void {
        self.grid.bound.controller.theme_library.filter = self.filter;
        self.grid.pending = true;
        self.grid.cx.requestRedraw();
    }
};

const Field = struct {
    bound: *binding.Binding,
    cx: *ui.Cx,
    key: binding.Key,
    text: *ui.Signal([]const u8),
    input: ui.widgets.input.InputResult = undefined,
    slider: ?*ui.Signal(f32) = null,
    error_box: *ui.Node = undefined,
    error_label: *ui.Node = undefined,
    edited: bool = false,
    fn create(cx: *ui.Cx, bound: *binding.Binding, key: binding.Key, width: f32, height: f32) !*Field {
        var buffer: [512]u8 = undefined;
        const current = values.read(bound.controller.model.value, key.section, key.key) orelse return error.UnknownKey;
        const raw = bound.controller.raw_fields[schema.find(key.section, key.key).?].input;
        const text = try bound.scope.createText(raw orelse try fieldDisplay(&buffer, current, key), .{});
        const self = try bound.scope.allocator.create(Field);
        self.* = .{ .bound = bound, .cx = cx, .key = key, .text = text };
        try bound.scope.onCleanup(Field, self, cleanup);
        const unit: ?[]const u8 = if (std.mem.eql(u8, key.key, "transparency")) "%" else if (std.mem.eql(u8, key.key, "blur_px")) "px" else if (std.mem.eql(u8, key.key, "font_size")) "pt" else null;
        self.input = try ui.widgets.Input(.{ .value = text, .append_text = unit, .on_change = cx.on(Field, self, edit), .on_submit = cx.on(Field, self, submit), .disabled = disabled(bound) }).mountResult(bound.scope, cx);
        self.input.input_container.setStyleInline(cx.allocator, S.field(width, height));
        if (unit != null) self.input.input_container.style.padding = .{ .left = 8, .right = 10 };
        self.input.node.style.width = .{ .px = width };
        self.input.node.style.flex_shrink = 0;
        S.tuneInput(&self.input);
        self.input.input_container.meta.ownership.meta.test_id = try id(bound.scope, "settings.field.", key.key);
        self.input.node.behavior.events.on_event_capture = onEvent;
        self.input.node.behavior.events.capture_context = self;
        self.input.input_container.behavior.events.on_event_capture = onEvent;
        self.input.input_container.behavior.events.capture_context = self;
        try bound.registerInput(self.input.state);
        try bound.registerEscape(self.input.state, self, escapeFromHost);
        self.error_box = try ui.boxStyled(cx, S.notice, .{});
        self.error_box.meta.ownership.meta.test_id = try id(bound.scope, "settings.error.", key.key);
        self.error_label = try ui.textStyled(cx, S.errorNote, "");
        textFill(self.error_label);
        try self.error_box.appendChild(cx.allocator, self.error_label);
        self.refresh();
        return self;
    }
    fn cleanup(self: *Field) void {
        self.bound.scope.allocator.destroy(self);
    }
    fn edit(self: *Field, text: []const u8) void {
        self.edited = true;
        self.bound.controller.editRaw(self.key.section, self.key.key, text) catch {};
        self.refresh();
        self.syncSlider();
        self.bound.valuesChanged();
    }
    fn submit(self: *Field, _: []const u8) void {
        if (self.input.state.imeIsComposing()) return;
        // Display rounding must not change a saved value on Enter without an edit.
        if (self.edited or !std.mem.eql(u8, self.key.key, "line_height")) self.bound.controller.editRaw(self.key.section, self.key.key, self.text.peek()) catch {};
        if (self.bound.hooks.appearance) |h| if (std.mem.eql(u8, self.key.section, "ui")) h.send(.validate_font);
        self.refresh();
        self.syncSlider();
        self.bound.valuesChanged();
    }
    fn syncSlider(self: *Field) void {
        if (self.slider) |slider| if (values.read(self.bound.controller.model.value, self.key.section, self.key.key)) |value| switch (value) {
            .unsigned => |n| slider.set(@floatFromInt(n)),
            .decimal => |n| slider.set(n),
            else => {},
        };
    }
    fn refresh(self: *Field) void {
        const problem = self.bound.controller.raw_fields[schema.find(self.key.section, self.key.key).?].problem;
        self.error_box.setDisplay(if (problem != null) .flex else .none);
        self.input.input_container.setBorderWidth(0);
        self.input.input_container.setBackground(if (problem != null) S.theme.current().danger.withAlpha(23) else S.theme.current().well);
        self.input.input_container.setBorderColor(ui.Color.TRANSPARENT);
        self.error_label.setTextContent(self.cx.allocator, if (problem) |err| fieldProblem(self.key, err) else "") catch {};
    }
    fn escape(self: *Field) void {
        const current = values.read(self.bound.controller.model.value, self.key.section, self.key.key) orelse return;
        var buffer: [512]u8 = undefined;
        const text = fieldDisplay(&buffer, current, self.key) catch return;
        self.edited = false;
        self.bound.controller.editKey(self.key.section, self.key.key, current) catch return;
        self.text.set(text);
        self.refresh();
        self.bound.valuesChanged();
    }
    fn escapeFromHost(raw: *anyopaque) void {
        const self: *Field = @ptrCast(@alignCast(raw));
        self.escape();
    }
    fn onEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Field = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event != .key_down or self.input.state.imeIsComposing()) return .ignored;
        if (event.key_down.key == .escape) {
            self.escape();
            return .stop;
        }
        return .ignored;
    }
};
fn fieldDisplay(buffer: []u8, value: values.Value, key: binding.Key) ![]const u8 {
    if (std.mem.eql(u8, key.key, "line_height") and value == .decimal) return std.fmt.bufPrint(buffer, "{d:.2}", .{value.decimal});
    return valueText(buffer, value);
}
fn valueText(buffer: []u8, value: values.Value) ![]const u8 {
    return switch (value) {
        .text => |t| t,
        .unsigned => |n| std.fmt.bufPrint(buffer, "{d}", .{n}),
        .decimal => |n| std.fmt.bufPrint(buffer, "{d}", .{n}),
        .boolean => |b| if (b) "true" else "false",
    };
}
fn fieldProblem(key: binding.Key, problem: anyerror) []const u8 {
    if (std.mem.eql(u8, key.key, "blur_px")) return "请输入 0–96 的整数；有效草稿保留，Esc 撤销本次输入。";
    if (std.mem.eql(u8, key.key, "transparency")) return "请输入 0–100 的有限数值；有效草稿保留，Esc 撤销本次输入。";
    if (std.mem.eql(u8, key.key, "font_size")) return "请输入 8–48 的整数。";
    if (std.mem.eql(u8, key.key, "line_height")) return "请输入 1.0–3.0 的有限数值，不含单位。";
    return @errorName(problem);
}

fn fieldRow(cx: *ui.Cx, bound: *binding.Binding, label: []const u8, help: ?[]const u8, control: *ui.Node) !*ui.Node {
    const row = try ui.boxStyled(cx, S.row, .{});
    const left = try ui.boxStyled(cx, S.labelGroup, .{});
    left.setStyleInline(cx.allocator, .{ .direction = .row, .align_items = .center, .gap = 4 });
    try left.appendChild(cx.allocator, try ui.textStyled(cx, S.label, label));
    if (help) |message| try left.appendChild(cx.allocator, try controls.inlineHint(cx, bound, try id(bound.scope, "settings.appearance.help.", label), message, ui.icons.circle_help, S.theme.current().fg_2));
    try row.appendChild(cx.allocator, left);
    try row.appendChild(cx.allocator, control);
    if (control.style.width == .px and control.style.width.px > 100) try Responsive.mount(cx, bound.scope, control, 220, 210);
    return row;
}

const Responsive = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    node: *ui.Node,
    standard: f32,
    compact: f32,
    fn mount(cx: *ui.Cx, scope: *ui.Scope, node: *ui.Node, standard: f32, compact: f32) !void {
        const self = try scope.allocator.create(Responsive);
        self.* = .{ .cx = cx, .scope = scope, .node = node, .standard = standard, .compact = compact };
        try scope.onCleanup(Responsive, self, cleanup);
        try cx.addAfterLayoutHook(self, afterLayout);
    }
    fn cleanup(self: *Responsive) void {
        self.cx.removeAfterLayoutHook(self);
        self.scope.allocator.destroy(self);
    }
    fn resize(self: *Responsive, node: *ui.Node, width: f32, root: bool) bool {
        var changed_width = false;
        const target = root or (self.standard <= 220 and if (node.meta.ownership.meta.test_id) |test_id| std.mem.startsWith(u8, test_id, "settings.field.") else false);
        if (target and (node.style.width != .px or node.style.width.px != width)) {
            node.setStyleInline(self.cx.allocator, .{ .width = .{ .px = width }, .flex_shrink = 0 });
            changed_width = true;
        }
        for (node.children.items) |child| changed_width = self.resize(child, width, false) or changed_width;
        return changed_width;
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Responsive = @ptrCast(@alignCast(raw));
        return if (self.resize(self.node, if (self.cx.viewport.width <= 900) self.compact else self.standard, true)) .needs_layout else .done;
    }
};

const Option = struct { label: []const u8, value: []const u8 };
fn choiceTrigger(cx: *ui.Cx, bound: *binding.Binding, label: []const u8, width: f32, height: f32) !*ui.Node {
    const button = try ui.widgets.Button(.{ .a11y_label = label, .variant = .ghost, .disabled = disabled(bound), .base_style = S.control(width, height) }).mount(bound.scope, cx);
    button.setStyleInline(cx.allocator, .{ .width = .{ .px = width }, .height = .{ .px = height }, .direction = .row, .align_items = .center, .justify = .start, .gap = 6, .padding = .{ .left = 10, .right = 8 }, .background = S.theme.current().well, .border = .{ .radius = 8, .width = 0 }, .flex_shrink = 0 });
    const text = try ui.textStyled(cx, S.value, label);
    textFill(text);
    try button.appendChild(cx.allocator, text);
    const arrow = try icon(cx, ui.icons.chevron_down, S.theme.current().fg_2);
    arrow.style.width = .{ .px = 14 };
    arrow.style.height = .{ .px = 14 };
    try button.appendChild(cx.allocator, arrow);
    return button;
}
fn chooser(cx: *ui.Cx, bound: *binding.Binding, key: binding.Key, shown: []const u8, options: []const Option, width: f32, height: f32, padding: f32, gap: f32, row_height: f32) !*ui.Node {
    const popover = try ui.widgets.Popover(.{ .position = .bottom_start, .width = width, .max_width = width, .max_height = height, .offset = .{ .static = 4 }, .viewport_padding = 8, .constrain_width_to_viewport = true, .shift_main_axis = true, .size_policy = .fit_content }).mount(bound.scope, cx);
    try bound.registerPopover(popover);
    popover.chrome.setStyleInline(cx.allocator, S.menu(width, padding, gap));
    popover.chrome.meta.ownership.meta.test_id = try id(bound.scope, "settings.chooser.", key.key);
    const control_width: f32 = 220;
    const button = try choiceTrigger(cx, bound, shown, control_width, 32);
    popover.wrapper.style.width = .{ .px = control_width };
    popover.wrapper.style.flex_shrink = 0;
    button.meta.ownership.meta.test_id = try id(bound.scope, "settings.field.", key.key);
    try popover.trigger.appendChild(cx.allocator, button);
    for (options) |option| {
        const click = try Click.create(popover.scope, bound, if (std.mem.eql(u8, option.value, "custom")) .custom_font else .choice, option.value);
        click.key = key;
        click.close = popover.close;
        const current = values.read(bound.controller.model.value, key.section, key.key);
        const selected = current != null and current.? == .text and std.mem.eql(u8, current.?.text, option.value);
        const item = try ui.widgets.Button(.{ .label = option.label, .variant = .ghost, .disabled = disabled(bound), .base_style = S.menuRow(row_height, selected), .on_click = cx.on(Click, click, Click.activate) }).mount(popover.scope, cx);
        item.setStyleInline(cx.allocator, S.menuRow(row_height, selected));
        item.meta.ownership.meta.test_id = try id(popover.scope, try id(popover.scope, "settings.option.", key.key), try id(popover.scope, ".", option.value));
        try popover.content.appendChild(cx.allocator, item);
    }
    return popover.wrapper;
}

fn matchesFontField(query: []const u8, key: []const u8, label: []const u8, help: []const u8) bool {
    return binding.matches(query, "字体与排版") or binding.matches(query, "终端字体、行距与光标") or binding.matches(query, key) or binding.matches(query, label) or binding.matches(query, help);
}
fn fontSection(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const c = bound.controller;
    var buffer: [256]u8 = undefined;
    const section = try card(cx, bound, "字体与排版", try std.fmt.bufPrint(&buffer, "{s} · {d} pt", .{ c.model.value.ui.font_family, c.model.value.ui.font_size }), ui.icons.type, 2, "settings.appearance.font");
    const query = c.search_query;
    if (matchesFontField(query, "font_family", "字体族", "未安装的字体使用系统替代字体。")) {
        const custom = if (bound.hooks.appearance) |h| h.custom_font_edit else false;
        if (custom) {
            const field = try Field.create(cx, bound, .{ .section = "ui", .key = "font_family" }, 220, 32);
            try section.body.appendChild(cx.allocator, try fieldRow(cx, bound, "字体族", "未安装所选字体时将使用替代字体；缺失字符由系统补足。", field.input.node));
            try section.body.appendChild(cx.allocator, field.error_box);
            if (bound.hooks.appearance) |h| {
                if (h.focus_custom_font) {
                    h.focus_custom_font = false;
                    cx.setFocus(field.input.input_container);
                }
            }
        } else {
            const control = try chooser(cx, bound, .{ .section = "ui", .key = "font_family" }, c.model.value.ui.font_family, &.{ .{ .label = "JetBrains Mono", .value = "JetBrains Mono" }, .{ .label = "Menlo", .value = "Menlo" }, .{ .label = "Monaco", .value = "Monaco" }, .{ .label = "自定义字体…", .value = "custom" } }, 220, 158, 10, 6, 30);
            try section.body.appendChild(cx.allocator, try fieldRow(cx, bound, "字体族", "未安装所选字体时将使用替代字体；缺失字符由系统补足。", control));
        }
    }
    if (matchesFontField(query, "font_size", "字体大小", "")) {
        const size = try Field.create(cx, bound, .{ .section = "ui", .key = "font_size" }, 220, 32);
        try section.body.appendChild(cx.allocator, try fieldRow(cx, bound, "字体大小", null, size.input.node));
        try section.body.appendChild(cx.allocator, size.error_box);
    }
    if (matchesFontField(query, "font_weight", "基准字重", "所选字体不支持此字重时，请选择其他字重后保存。")) {
        const weight_label: []const u8 = if (std.mem.eql(u8, c.model.value.ui.font_weight, "light")) "Light" else if (std.mem.eql(u8, c.model.value.ui.font_weight, "medium")) "Medium" else if (std.mem.eql(u8, c.model.value.ui.font_weight, "bold")) "Bold" else "Regular";
        const weight = try chooser(cx, bound, .{ .section = "ui", .key = "font_weight" }, weight_label, &.{ .{ .label = "Light", .value = "light" }, .{ .label = "Regular", .value = "regular" }, .{ .label = "Medium", .value = "medium" }, .{ .label = "Bold", .value = "bold" } }, 220, 158, 10, 6, 30);
        try section.body.appendChild(cx.allocator, try fieldRow(cx, bound, "基准字重", "所选字体不支持此字重时，请选择其他字重后保存。", weight));
    }
    if (matchesFontField(query, "line_height", "行高倍率", "")) {
        const line = try Field.create(cx, bound, .{ .section = "ui", .key = "line_height" }, 220, 32);
        try section.body.appendChild(cx.allocator, try fieldRow(cx, bound, "行高倍率", null, line.input.node));
        try section.body.appendChild(cx.allocator, line.error_box);
    }
    try section.body.appendChild(cx.allocator, try cursorField(cx, bound));
    try section.body.appendChild(cx.allocator, try fontPreview(cx, bound));
    const status = try ui.textStyled(cx, S.errorNote, "");
    status.meta.ownership.meta.test_id = "settings.font.status";
    bound.font_status_label = status;
    try section.body.appendChild(cx.allocator, status);
    bound.refreshFooter();
    return section.root;
}

const cursor_options = [_]ui.widgets.checkbox.RadioOption{
    .{ .value = "block", .label = "方块", .test_id = "settings.option.cursor_style.block" },
    .{ .value = "bar", .label = "竖线", .test_id = "settings.option.cursor_style.bar" },
    .{ .value = "underline", .label = "下划线", .test_id = "settings.option.cursor_style.underline" },
};
const CursorSelect = struct {
    bound: *binding.Binding,
    fn cleanup(self: *CursorSelect) void {
        self.bound.scope.allocator.destroy(self);
    }
    fn change(self: *CursorSelect, value: []const u8) void {
        if (disabled(self.bound)) return;
        self.bound.controller.editKey("ui", "cursor_style", .{ .text = value }) catch return;
        self.bound.valuesChanged();
        changed(self.bound);
    }
};
fn cursorShape(cx: *ui.Cx, value: []const u8) !*ui.Node {
    return ui.box(cx, .{ .width = .{ .px = if (std.mem.eql(u8, value, "bar")) 2 else 9 }, .height = .{ .px = if (std.mem.eql(u8, value, "underline")) 2 else 16 }, .background = S.theme.current().accent_ink, .flex_shrink = 0, .align_self = if (std.mem.eql(u8, value, "underline")) .end else .center }, .{});
}
fn cursorField(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const row = try ui.boxStyled(cx, S.row, .{});
    row.style.padding.top = 12;
    row.style.padding.bottom = 12;
    const labels = try ui.boxStyled(cx, S.labelGroup, .{});
    try labels.appendChild(cx.allocator, try ui.textStyled(cx, S.label, "光标样式"));
    labels.setStyleInline(cx.allocator, .{ .direction = .row, .align_items = .center, .gap = 4 });
    try labels.appendChild(cx.allocator, try controls.inlineHint(cx, bound, "settings.appearance.help.cursor_style", "选择形状，在下方终端中查看。", ui.icons.circle_help, S.theme.current().fg_2));
    try row.appendChild(cx.allocator, labels);
    const select = try bound.scope.allocator.create(CursorSelect);
    select.* = .{ .bound = bound };
    try bound.scope.onCleanup(CursorSelect, select, CursorSelect.cleanup);
    const group = try ui.widgets.RadioGroup(.{ .options = &cursor_options, .value = @as(?[]const u8, bound.controller.model.value.ui.cursor_style), .horizontal = true, .disabled = disabled(bound), .on_change = cx.on(CursorSelect, select, CursorSelect.change) }).mount(bound.scope, cx);
    group.setStyleInline(cx.allocator, .{ .width = .{ .px = 220 }, .height = .{ .px = 40 }, .direction = .row, .gap = 6, .align_items = .center, .flex_shrink = 0 });
    group.meta.ownership.meta.test_id = "settings.field.cursor_style";
    for (group.children.items, cursor_options) |radio, option| {
        const selected = std.mem.eql(u8, option.value, bound.controller.model.value.ui.cursor_style);
        radio.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0, .height = .{ .px = 40 }, .gap = 4, .align_items = .center, .flex_shrink = 0 });
        // Preserve the widget-owned circle: selection effects still refer to it.
        // The cursor sample communicates shape, while the circle communicates choice.
        const circle = radio.children.items[0];
        circle.setStyleInline(cx.allocator, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .background = if (selected) S.theme.current().accent_ink else ui.Color.TRANSPARENT, .border = .{ .width = 1.5, .color = if (selected) S.theme.current().accent_ink else S.theme.current().fg_2, .radius = 6 } });
        const label = radio.children.items[1];
        if (label.getText()) |old| {
            var props = old;
            props.font_size = 11;
            props.color = S.theme.current().fg_1;
            label.setText(props);
        }
        const demo = try ui.box(cx, .{ .width = .{ .px = 14 }, .height = .{ .px = 24 }, .align_items = .center, .justify = .center, .background = S.theme.current().surface_2, .border = .{ .radius = 3 }, .flex_shrink = 0 }, .{});
        try demo.appendChild(cx.allocator, try cursorShape(cx, option.value));
        try radio.insertChildBefore(cx.allocator, demo, label);
    }
    try Responsive.mount(cx, bound.scope, group, 220, 210);
    try row.appendChild(cx.allocator, group);
    return row;
}
fn fontPreview(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const setting = bound.controller.model.value.ui;
    const status: @import("../appearance_ui_context.zig").FontStatus = if (bound.hooks.appearance) |host| if (host.font_status) |read| read(host.context) else .{} else .{};
    const family: u16 = if (@hasField(@TypeOf(status), "family_id")) status.family_id else 0;
    const actual = if (status.actual_family.len != 0) status.actual_family else "系统等宽字体";
    const root = try ui.box(cx, .{ .width = .fill(), .direction = .column, .gap = 9, .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 }, .margin = .{ .top = 4, .bottom = 7 }, .background = S.theme.current().well, .border = .{ .radius = 8 }, .flex_shrink = 0 }, .{});
    root.meta.ownership.meta.test_id = "settings.font.preview";
    const heading = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 16 }, .direction = .row, .gap = 6, .align_items = .center }, .{});
    try heading.appendChild(cx.allocator, try icon(cx, ui.icons.terminal, S.theme.current().fg_2));
    try heading.appendChild(cx.allocator, try ui.textStyled(cx, S.note, "终端预览"));
    try heading.appendChild(cx.allocator, try ui.spacer(cx));
    var buffer: [256]u8 = undefined;
    try heading.appendChild(cx.allocator, try ui.textStyled(cx, S.note, try owned(bound.scope, try std.fmt.bufPrint(&buffer, "{s} · {d} pt", .{ actual, setting.font_size }))));
    try root.appendChild(cx.allocator, heading);
    if (status.fallback) {
        var message_buffer: [512]u8 = undefined;
        const message = try owned(bound.scope, try std.fmt.bufPrint(&message_buffer, "请求字体 {s} 当前不可用，预览使用 {s}。", .{ setting.font_family, actual }));
        try root.appendChild(cx.allocator, try ui.text(cx, message, .{ .font_size = 11, .line_height = 17.0 / 11.0, .color = S.theme.current().warn_ink, .wrap = .word }));
    }
    const code = try ui.box(cx, .{ .width = .fill(), .min_height = 48, .direction = .column, .flex_shrink = 0 }, .{});
    const line_height = @as(f32, @floatFromInt(setting.font_size)) * setting.line_height;
    const weight: u16 = if (std.mem.eql(u8, setting.font_weight, "bold")) 700 else if (std.mem.eql(u8, setting.font_weight, "medium")) 500 else if (std.mem.eql(u8, setting.font_weight, "light")) 300 else 400;
    const first = try ui.text(cx, "user@ZeroWork ~", .{ .font_size = @floatFromInt(setting.font_size), .font_weight = weight, .font_family = family, .use_monospace_font = family == 0, .line_height = setting.line_height, .color = S.theme.current().ok_ink });
    try code.appendChild(cx.allocator, first);
    const command = try ui.box(cx, .{ .height = .{ .px = line_height }, .direction = .row, .align_items = .center, .gap = 2 }, .{});
    try command.appendChild(cx.allocator, try ui.text(cx, "$ ssh prod-web-01", .{ .font_size = @floatFromInt(setting.font_size), .font_weight = weight, .font_family = family, .use_monospace_font = family == 0, .line_height = setting.line_height, .color = S.theme.current().fg_1 }));
    const caret = try cursorShape(cx, setting.cursor_style);
    caret.meta.ownership.meta.test_id = "settings.font.preview.caret";
    try CursorBlink.mount(cx, bound.scope, root, caret);
    try command.appendChild(cx.allocator, caret);
    try code.appendChild(cx.allocator, command);
    try root.appendChild(cx.allocator, code);
    return root;
}

// A single timed wakeup per half-period, removed with the settings page Scope.
const CursorBlink = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    root: *ui.Node,
    caret: *ui.Node,
    epoch_ms: f64,
    visible: bool = true,
    fn mount(cx: *ui.Cx, scope: *ui.Scope, root: *ui.Node, caret: *ui.Node) !void {
        const self = try scope.allocator.create(CursorBlink);
        self.* = .{ .cx = cx, .scope = scope, .root = root, .caret = caret, .epoch_ms = cx.eventTimeMs() };
        try scope.onCleanup(CursorBlink, self, cleanup);
        try cx.addAfterLayoutHook(self, afterLayout);
        cx.scheduleRedrawAfterNs(550 * std.time.ns_per_ms);
    }
    fn cleanup(self: *CursorBlink) void {
        self.cx.removeAfterLayoutHook(self);
        self.scope.allocator.destroy(self);
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *CursorBlink = @ptrCast(@alignCast(raw));
        const preview = self.root.globalRect();
        var ancestor: ?*ui.Node = self.root;
        while (ancestor) |node| : (ancestor = node.parent) {
            if (node.style.display == .none) return .done;
            if (node.style.overflow_hidden or node.style.overflow == .hidden) {
                const clip = node.globalRect();
                if (preview.x >= clip.x + clip.w or preview.x + preview.w <= clip.x or preview.y >= clip.y + clip.h or preview.y + preview.h <= clip.y) return .done;
            }
        }
        const elapsed = @max(@as(f64, 0), self.cx.eventTimeMs() - self.epoch_ms);
        const visible = @mod(@floor(elapsed / 550), 2) == 0;
        if (visible != self.visible) {
            self.visible = visible;
            self.caret.setOpacity(if (visible) 1 else 0);
        }
        self.cx.scheduleRedrawAfterNs(@intFromFloat(@max(@as(f64, 1), 550 - @mod(elapsed, 550)) * std.time.ns_per_ms));
        return .done;
    }
};

fn toggle(cx: *ui.Cx, bound: *binding.Binding, key: binding.Key, label: []const u8) !*ui.Node {
    const current = values.read(bound.controller.model.value, key.section, key.key).?.boolean;
    const click = try Click.create(bound.scope, bound, .toggle, "");
    click.key = key;
    const button = try ui.widgets.Button(.{ .a11y_label = label, .variant = .ghost, .disabled = disabled(bound), .on_click = cx.on(Click, click, Click.activate), .base_style = S.toggle(current) }).mount(bound.scope, cx);
    button.setStyleInline(cx.allocator, S.toggle(current));
    button.meta.ownership.meta.test_id = try id(bound.scope, "settings.toggle.", key.key);
    if (button.behavior.interaction.a11y) |*a| {
        a.role = .switch_role;
        a.checked = current;
    }
    try button.appendChild(cx.allocator, try ui.boxStyled(cx, S.toggleKnob, .{}));
    return button;
}
fn aidsSection(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const section = try card(cx, bound, "终端与工作区", "辅助显示、回滚缓冲与侧栏", ui.icons.terminal, 3, "settings.appearance.aids");
    for ([_]struct { label: []const u8, key: binding.Key, help: ?[]const u8 }{
        .{ .label = "时间戳侧栏", .key = .{ .section = "ui", .key = "timestamp_gutter" }, .help = "显示输出时间，不包含在复制的终端内容中。" },
        .{ .label = "应用命令补全", .key = .{ .section = "completion", .key = "enabled" }, .help = null },
        .{ .label = "输入行相对高亮", .key = .{ .section = "ui", .key = "input_line_highlight" }, .help = null },
        .{ .label = "默认隐藏侧栏", .key = .{ .section = "ui", .key = "sidebar_collapsed" }, .help = "保存侧栏显示偏好；⌘B 随时显示或隐藏。" },
    }) |field| {
        const control = try ui.box(cx, .{ .width = .{ .px = 44 }, .height = .{ .px = 18 }, .direction = .row, .align_items = .center, .justify = .end, .flex_shrink = 0 }, .{});
        try control.appendChild(cx.allocator, try toggle(cx, bound, field.key, field.label));
        try section.body.appendChild(cx.allocator, try fieldRow(cx, bound, field.label, field.help, control));
    }
    const limit = try Field.create(cx, bound, .{ .section = "ui", .key = "scrollback_limit" }, 120, 32);
    try section.body.appendChild(cx.allocator, try fieldRow(cx, bound, "终端最大显示行数", "默认 25000 行；0 表示不限制。同步应用到已打开的本地终端和继承全局配置的 SSH 终端。", limit.input.node));
    try section.body.appendChild(cx.allocator, limit.error_box);
    if (bound.hooks.appearance) |h| if (h.registry.get(bound.controller.model.value.ui.theme)) |record| try section.body.appendChild(cx.allocator, try miniPreview(cx, record, bound.controller.model.value.ui.timestamp_gutter, bound.controller.model.value.ui.input_line_highlight, bound.controller.model.value.ui.sidebar_collapsed));
    return section.root;
}

fn materialSection(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const c = bound.controller;
    const background = c.model.value.ui.materials.background;
    const summary = try std.fmt.allocPrint(bound.scope.allocator, "{s} · {s}", .{ if (background.enabled) @as([]const u8, "已开启") else "已关闭", if (background.path.len == 0) @as([]const u8, "未选择图片") else background.path });
    defer bound.scope.allocator.free(summary);
    const section = try card(cx, bound, "背景图片", summary, ui.icons.image, 1, "settings.appearance.materials");
    section.header.meta.ownership.meta.test_id = "settings.materials.header";
    const toggle_node = try toggle(cx, bound, .{ .section = "ui.materials.background", .key = "enabled" }, "开启背景图片");
    // The enable control is a sibling of the Accordion trigger. Its click must
    // not bubble into folding; both controls keep their stock keyboard handling.
    section.root.setStyleInline(cx.allocator, .{ .position = .relative });
    toggle_node.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .right = .{ .px = 36 }, .top = .{ .px = if (bound.controller.search_query.len != 0 or bound.controller.folded_sections & (@as(u64, 1) << 1) == 0) @as(f32, 15) else 22 } } });
    section.header.children.items[1].style.padding.right = 46;
    try section.root.appendChild(cx.allocator, toggle_node);
    const root = section.body;
    if (!background.enabled) try root.appendChild(cx.allocator, try notice(cx, "背景图片已关闭。透明度和模糊仍对界面生效。", false));
    const image = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 68 }, .direction = .row, .align_items = .center, .gap = 10, .flex_shrink = 0, .min_width = 0 }, .{});
    image.meta.ownership.meta.test_id = "settings.background.identity";
    const preview = try Click.create(bound.scope, bound, .preview_material, "");
    const preview_button = try ui.widgets.Button(.{ .a11y_label = "材质预览", .variant = .ghost, .disabled = bound.hooks.appearance == null or disabled(bound), .on_click = cx.on(Click, preview, Click.activate), .base_style = S.plainButton(72, 48, false) }).mount(bound.scope, cx);
    preview_button.setStyleInline(cx.allocator, .{ .width = .{ .px = 72 }, .height = .{ .px = 48 }, .padding = .ZERO, .margin = .{ .right = 2, .bottom = 4 }, .flex_shrink = 0 });
    preview_button.meta.ownership.meta.test_id = "settings.materials.preview.open";
    // Retained last-good resources still serve failed replacements and the
    // committed window background; an explicitly removed draft has no thumbnail.
    if (background.path.len == 0) {
        try preview_button.appendChild(cx.allocator, try icon(cx, ui.icons.image, S.theme.current().fg_3));
    } else if (bound.hooks.appearance) |h| {
        if (h.mount_image) |mount| {
            try preview_button.appendChild(cx.allocator, try mount(h.context, cx, bound.scope, 72, 48));
        } else try preview_button.appendChild(cx.allocator, try icon(cx, ui.icons.image, S.theme.current().fg_3));
    } else try preview_button.appendChild(cx.allocator, try icon(cx, ui.icons.image, S.theme.current().fg_3));
    try image.appendChild(cx.allocator, preview_button);
    const identity = try ui.boxStyled(cx, S.column, .{});
    identity.style.gap = 2;
    identity.style.padding.right = 12;
    textFill(identity);
    const path = if (bound.hooks.appearance) |h| if (h.selected_image_path.len != 0) h.selected_image_path else background.path else background.path;
    const full_path = try owned(bound.scope, path);
    const tip = try ui.widgets.Tooltip(.{ .text = full_path, .open_delay_ms = 450 }).mount(bound.scope, cx);
    const name = try ui.text(cx, if (path.len == 0) "尚未选择图片" else std.fs.path.basename(path), .{ .font_size = 11.5, .font_weight = 500, .line_height = 18.0 / 11.5, .color = S.theme.current().fg_1 });
    textFill(name);
    name.meta.ownership.meta.test_id = "settings.background.filename";
    try tip.trigger.appendChild(cx.allocator, name);
    tip.wrapper.style.width = .fill();
    tip.trigger.style.width = .fill();
    try identity.appendChild(cx.allocator, tip.wrapper);
    var status_buffer: [96]u8 = undefined;
    const status: []const u8 = switch (c.background.state) {
        .loading => "正在读取与解码…",
        .missing => "文件已移动 · 草稿保留",
        .denied => "权限不足 · 草稿保留",
        .invalid => "图片无法解码 · 草稿保留",
        .failed => "图片准备失败 · 草稿保留",
        .empty => if (path.len == 0) "从本机选择一张图片" else "等待准备图片",
        .ready => if (c.background.last_good) |good| try std.fmt.bufPrint(&status_buffer, "本地 · {d} × {d}", .{ good.image.width, good.image.height }) else "等待准备图片",
    };
    const status_text = try ui.text(cx, status, if (c.background.problem != null) S.errorNote(undefined) else S.note(undefined));
    status_text.meta.ownership.meta.test_id = "settings.background.state";
    try identity.appendChild(cx.allocator, status_text);
    try image.appendChild(cx.allocator, identity);
    const choose = try Click.create(bound.scope, bound, .choose_image, "");
    const choose_button = try ui.widgets.Button(.{ .label = if (path.len == 0) "选择图片" else "更换图片", .icon_asset = ui.icons.folder_open, .icon_size = @as(f32, 14), .variant = .secondary, .disabled = bound.hooks.appearance == null or disabled(bound), .on_click = cx.on(Click, choose, Click.activate), .base_style = S.control(100, 32), .hover_style = S.base.buttonHover() }).mount(bound.scope, cx);
    choose_button.meta.ownership.meta.test_id = "settings.background.choose";
    try image.appendChild(cx.allocator, choose_button);
    try image.appendChild(cx.allocator, try iconButton(cx, bound.scope, bound, .remove_image, "", ui.icons.trash, "移除背景图片", "settings.background.remove", 32, background.path.len == 0 or disabled(bound)));
    try root.appendChild(cx.allocator, image);
    const fit = try chooser(cx, bound, .{ .section = "ui.materials.background", .key = "fit" }, switch (background.fit) {
        .fill => "填充 · Fill",
        .fit => "适应 · Fit",
        .center => "居中 · Center",
        .tile => "平铺 · Tile",
    }, &.{ .{ .label = "填充 · Fill", .value = "fill" }, .{ .label = "适应 · Fit", .value = "fit" }, .{ .label = "居中 · Center", .value = "center" }, .{ .label = "平铺 · Tile", .value = "tile" } }, 176, 148, 8, 4, 30);
    try root.appendChild(cx.allocator, try fieldRow(cx, bound, "图片适配", null, fit));
    try root.appendChild(cx.allocator, try fieldRow(cx, bound, "图片对齐", null, try alignmentChooser(cx, bound)));
    const sliders = try ui.boxStyled(cx, S.column, .{});
    const transparency = try sliderRow(cx, bound, "全局透明度", .{ .section = "ui.materials.background", .key = "transparency" }, background.transparency, 100, 0);
    const blur = try sliderRow(cx, bound, "背景与浮层模糊", .{ .section = "ui.materials", .key = "blur_px" }, @floatFromInt(c.model.value.ui.materials.blur_px), 96, 1);
    try sliders.appendChild(cx.allocator, transparency.row);
    try sliders.appendChild(cx.allocator, blur.row);
    try root.appendChild(cx.allocator, sliders);
    try root.appendChild(cx.allocator, transparency.field.error_box);
    try root.appendChild(cx.allocator, blur.field.error_box);
    if (background.path.len != 0) try root.appendChild(cx.allocator, try materialInlinePreview(cx, bound));
    return section.root;
}

fn materialInlinePreview(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const root = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 116 }, .position = .relative, .margin = .{ .top = 10, .bottom = 5 }, .background = S.theme.current().well, .border = .{ .radius = 8 }, .overflow = .hidden, .overflow_hidden = true, .flex_shrink = 0 }, .{});
    root.meta.ownership.meta.test_id = "settings.background.preview";
    if (bound.hooks.appearance) |h| if (h.mount_material_preview) |mount| {
        const material = try mount(h.context, cx, bound.scope, 0, 116);
        material.meta.ownership.meta.test_id = "settings.background.preview.image";
        try root.appendChild(cx.allocator, material);
    };
    const title = try ui.textStyled(cx, S.note, "背景预览");
    title.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 11 }, .top = .{ .px = 9 } } });
    try root.appendChild(cx.allocator, title);
    const code = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 12 }, .bottom = .{ .px = 14 } }, .direction = .column, .gap = 0 }, .{});
    for ([_][]const u8{ "user@ZeroWork ~", "$ ssh prod-web-01" }) |line| try code.appendChild(cx.allocator, try ui.text(cx, line, .{ .font_size = 12, .use_monospace_font = true, .line_height = 20.0 / 12.0, .color = S.theme.current().fg_1 }));
    try root.appendChild(cx.allocator, code);
    const preview = try textAction(cx, bound, .preview_material, "", "全窗口预览", "使用整个工作区预览当前材质草稿", "settings.materials.preview.full", false, disabled(bound));
    preview.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .right = .{ .px = 11 }, .top = .{ .px = 4 } } });
    try root.appendChild(cx.allocator, preview);
    return root;
}

fn sliderRow(cx: *ui.Cx, bound: *binding.Binding, label: []const u8, key: binding.Key, value: f32, max: f32, step: f32) !struct { row: *ui.Node, field: *Field } {
    const row = try ui.boxStyled(cx, S.row, .{});
    const labels = try ui.boxStyled(cx, S.labelGroup, .{});
    try labels.appendChild(cx.allocator, try ui.textStyled(cx, S.label, label));
    if (step == 0) {
        labels.setStyleInline(cx.allocator, .{ .direction = .row, .align_items = .center, .gap = 4 });
        try labels.appendChild(cx.allocator, try controls.inlineHint(cx, bound, "settings.appearance.help.transparency", "数值越大，图片越透明。", ui.icons.circle_help, S.theme.current().fg_2));
    }
    try row.appendChild(cx.allocator, labels);
    const controls_group = try ui.box(cx, .{ .width = .{ .px = 350 }, .height = .{ .px = 32 }, .direction = .row, .gap = 12, .align_items = .center, .flex_shrink = 0 }, .{});
    try Responsive.mount(cx, bound.scope, controls_group, 350, 250);
    try row.appendChild(cx.allocator, controls_group);
    const signal = try bound.scope.createSignal(f32, value);
    const number = try Field.create(cx, bound, key, 90, 32);
    number.slider = signal;
    const slider = try bound.scope.allocator.create(SliderEdit);
    slider.* = .{ .field = number, .integer = step != 0 };
    try bound.scope.onCleanup(SliderEdit, slider, SliderEdit.cleanup);
    const result = try ui.widgets.Slider(.{ .value = signal, .min = @as(f32, 0), .max = max, .step = step, .width = @as(f32, 328), .track_height = @as(f32, 4), .thumb_size = @as(f32, 16), .disabled = disabled(bound), .on_change = cx.on(SliderEdit, slider, SliderEdit.change), .test_id = try id(bound.scope, "settings.slider.", key.key) }).mount(bound.scope, cx);
    result.wrapper.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .height = .{ .px = 32 }, .min_width = 0, .align_items = .center, .padding = .{ .left = 8, .right = 8 } });
    try controls_group.appendChild(cx.allocator, result.wrapper);
    try controls_group.appendChild(cx.allocator, number.input.node);
    return .{ .row = row, .field = number };
}
const SliderEdit = struct {
    field: *Field,
    integer: bool,
    fn cleanup(self: *SliderEdit) void {
        self.field.bound.scope.allocator.destroy(self);
    }
    fn change(self: *SliderEdit, value: f32) void {
        const field = self.field;
        field.bound.controller.editKey(field.key.section, field.key.key, if (self.integer) .{ .unsigned = @intFromFloat(value) } else .{ .decimal = value }) catch return;
        var buffer: [64]u8 = undefined;
        const text = valueText(&buffer, values.read(field.bound.controller.model.value, field.key.section, field.key.key).?) catch return;
        field.text.set(text);
        field.refresh();
        field.bound.valuesChanged();
    }
};

fn alignmentChooser(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const background = bound.controller.model.value.ui.materials.background;
    const popover = try ui.widgets.Popover(.{ .position = .bottom_start, .width = @as(f32, 120), .max_width = @as(f32, 120), .max_height = @as(f32, 120), .size_policy = .fit_content, .offset = .{ .static = 4 }, .viewport_padding = @as(f32, 8) }).mount(bound.scope, cx);
    try bound.registerPopover(popover);
    popover.chrome.setStyleInline(cx.allocator, S.menu(120, 8, 4));
    popover.chrome.meta.ownership.meta.test_id = "settings.chooser.alignment";
    const names = [3][3][]const u8{ .{ "左上", "顶部居中", "右上" }, .{ "左侧居中", "居中", "右侧居中" }, .{ "左下", "底部居中", "右下" } };
    const x: @import("../background_asset.zig").Horizontal = background.alignment_x;
    const y: @import("../background_asset.zig").Vertical = background.alignment_y;
    const label = names[@backingInt(y)][@backingInt(x)];
    const trigger = try choiceTrigger(cx, bound, label, 220, 32);
    popover.wrapper.style.width = .{ .px = 220 };
    popover.wrapper.style.flex_shrink = 0;
    trigger.meta.ownership.meta.test_id = "settings.field.alignment";
    try popover.trigger.appendChild(cx.allocator, trigger);
    for (0..3) |vertical| {
        const row = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .gap = 4, .flex_shrink = 0 }, .{});
        for (0..3) |horizontal| {
            const choice = try popover.scope.allocator.create(AlignmentClick);
            choice.* = .{ .bound = bound, .scope = popover.scope, .horizontal = @fromBackingInt(@intCast(horizontal)), .vertical = @fromBackingInt(@intCast(vertical)), .close = popover.close };
            try popover.scope.onCleanup(AlignmentClick, choice, AlignmentClick.cleanup);
            const chosen = horizontal == @backingInt(x) and vertical == @backingInt(y);
            const button = try ui.widgets.Button(.{ .a11y_label = names[vertical][horizontal], .icon_only = true, .icon_asset = ui.icons.circle, .icon_size = @as(f32, 6), .variant = .ghost, .disabled = disabled(bound), .base_style = S.plainButton(32, 32, chosen), .on_click = cx.on(AlignmentClick, choice, AlignmentClick.activate) }).mount(popover.scope, cx);
            button.meta.ownership.meta.test_id = try id(popover.scope, "settings.alignment.", names[vertical][horizontal]);
            try row.appendChild(cx.allocator, button);
        }
        try popover.content.appendChild(cx.allocator, row);
    }
    return popover.wrapper;
}
const AlignmentClick = struct {
    bound: *binding.Binding,
    scope: *ui.Scope,
    horizontal: @import("../background_asset.zig").Horizontal,
    vertical: @import("../background_asset.zig").Vertical,
    close: ui.Handler(void),
    fn cleanup(self: *AlignmentClick) void {
        self.scope.allocator.destroy(self);
    }
    fn activate(self: *AlignmentClick) void {
        self.bound.controller.editBackgroundAlignment(self.horizontal, self.vertical) catch return;
        self.close.invoke();
        self.bound.valuesChanged();
        changed(self.bound);
    }
};

pub fn mountMaterialPreviewActions(cx: *ui.Cx, scope: *ui.Scope, bound: *binding.Binding) !*ui.Node {
    const root = try ui.boxStyled(cx, S.previewBar, .{});
    root.meta.ownership.meta.test_id = "settings.materials.preview.actions";
    try root.appendChild(cx.allocator, try icon(cx, ui.icons.eye, S.theme.current().fg_2));
    const label = try ui.textStyled(cx, S.label, "背景预览");
    label.style.width = .{ .px = 120 };
    try root.appendChild(cx.allocator, label);
    var buffer: [64]u8 = undefined;
    const materials = bound.controller.model.value.ui.materials;
    const status = try ui.textStyled(cx, S.value, try std.fmt.bufPrint(&buffer, "{d}% · {d}px", .{ materials.background.transparency, materials.blur_px }));
    status.style.width = .{ .px = 120 };
    try root.appendChild(cx.allocator, status);
    try root.appendChild(cx.allocator, try ui.spacer(cx));
    try root.appendChild(cx.allocator, try iconButton(cx, scope, bound, .restore_material, "", ui.icons.rotate_ccw, "恢复已保存的背景", "settings.materials.preview.restore", 32, disabled(bound)));
    try root.appendChild(cx.allocator, try iconButton(cx, scope, bound, .return_material, "", ui.icons.arrow_left, "返回设置", "settings.materials.preview.return", 32, false));
    const save = try bound.actionButton(cx, .save, ui.icons.save, "保存全部设置", "settings.materials.preview.save", true);
    save.button.style.width = .{ .px = 128 };
    save.button.style.flex_shrink = 0;
    save.button.style.height = .{ .px = 32 };
    try root.appendChild(cx.allocator, save.wrapper);
    return root;
}

const app_icon_options = [_]ui.widgets.checkbox.RadioOption{
    .{ .value = "transparent", .label = "透明背景", .test_id = "settings.option.icon_background.transparent" },
    .{ .value = "dark", .label = "黑底", .test_id = "settings.option.icon_background.dark" },
    .{ .value = "light", .label = "白底", .test_id = "settings.option.icon_background.light" },
};
const AppIconSelect = struct {
    bound: *binding.Binding,
    fn cleanup(self: *AppIconSelect) void {
        self.bound.scope.allocator.destroy(self);
    }
    fn change(self: *AppIconSelect, value: []const u8) void {
        if (disabled(self.bound)) return;
        self.bound.controller.editKey("ui", "icon_background", .{ .text = value }) catch return;
        self.bound.valuesChanged();
        changed(self.bound);
    }
};
fn appIconSection(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const section = try card(cx, bound, "应用图标", "Dock 图标底色 · 保存后生效", ui.icons.terminal, 3, "settings.appearance.app_icon");
    const row = try ui.boxStyled(cx, S.row, .{});
    row.style.padding.top = 12;
    row.style.padding.bottom = 12;
    const labels = try ui.boxStyled(cx, S.labelGroup, .{});
    labels.setStyleInline(cx.allocator, .{ .direction = .row, .align_items = .center, .gap = 4 });
    try labels.appendChild(cx.allocator, try ui.textStyled(cx, S.label, "图标背景"));
    try labels.appendChild(cx.allocator, try controls.inlineHint(cx, bound, "settings.appearance.help.icon_background", "保存后切换 Dock，重启后保留。Finder 与启动台使用默认透明图标。", ui.icons.circle_help, S.theme.current().fg_2));

    try row.appendChild(cx.allocator, labels);
    const select = try bound.scope.allocator.create(AppIconSelect);
    select.* = .{ .bound = bound };
    try bound.scope.onCleanup(AppIconSelect, select, AppIconSelect.cleanup);
    const group = try ui.widgets.RadioGroup(.{ .options = &app_icon_options, .value = @as(?[]const u8, @tagName(bound.controller.model.value.ui.icon_background)), .horizontal = true, .disabled = disabled(bound), .on_change = cx.on(AppIconSelect, select, AppIconSelect.change) }).mount(bound.scope, cx);
    group.meta.ownership.meta.test_id = "settings.field.icon_background";
    group.setStyleInline(cx.allocator, .{ .height = .{ .px = 40 }, .direction = .row, .gap = 24, .align_items = .center, .flex_shrink = 0 });
    // Keep a single radio-circle treatment, with no button surface.
    for (group.children.items, app_icon_options) |radio, option| {
        const selected = std.mem.eql(u8, option.value, @tagName(bound.controller.model.value.ui.icon_background));
        radio.setStyleInline(cx.allocator, .{ .height = .{ .px = 40 }, .gap = 8, .align_items = .center, .flex_shrink = 0 });
        radio.children.items[0].setStyleInline(cx.allocator, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .background = if (selected) S.theme.current().accent_ink else ui.Color.TRANSPARENT, .border = .{ .width = 1.5, .color = if (selected) S.theme.current().accent_ink else S.theme.current().fg_2, .radius = 9 } });
    }
    try row.appendChild(cx.allocator, group);
    try section.body.appendChild(cx.allocator, row);
    return section.root;
}
