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

const Card = struct { root: *ui.Node, body: *ui.Node };
fn card(cx: *ui.Cx, bound: *binding.Binding, title: []const u8, summary: []const u8, asset: ui.SvgAsset, bit: u6, test_id: []const u8) !Card {
    const fold = try bound.scope.allocator.create(Fold);
    fold.* = .{ .bound = bound, .bit = bit };
    try bound.scope.onCleanup(Fold, fold, Fold.cleanup);
    const expanded = bound.controller.search_query.len != 0 or bound.controller.folded_sections & (@as(u64, 1) << bit) == 0;
    const result = try ui.widgets.AccordionItem(.{ .title = title, .expanded = expanded, .variant = .ghost, .on_change = cx.on(Fold, fold, Fold.change) }).mount(bound.scope, cx);
    _ = try controls.sectionHeader(cx, bound.scope, result, asset, expanded, summary, test_id);
    result.item.meta.ownership.meta.test_id = test_id;
    result.header.meta.ownership.meta.test_id = try id(bound.scope, test_id, ".header");
    if (disabled(bound)) {
        result.header.behavior.events.on_event = null;
        result.header.setFocusable(false);
    }
    result.body.setStyleInline(cx.allocator, S.column(undefined));
    result.body.style.padding = .ZERO;
    return .{ .root = result.item, .body = result.body };
}
const Fold = struct {
    bound: *binding.Binding,
    bit: u6,
    fn cleanup(self: *Fold) void {
        self.bound.scope.allocator.destroy(self);
    }
    fn change(self: *Fold, open: bool) void {
        if (disabled(self.bound)) return;
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
    if (query.len == 0 or binding.matches(query, "外观 主题 theme 主题库")) try root.appendChild(cx.allocator, try themeSection(cx, bound));
    if (query.len == 0 or binding.matches(query, "背景 图片 材质 模糊 透明度 fit 对齐 blur_px background enabled path alignment_x alignment_y transparency")) try root.appendChild(cx.allocator, try materialSection(cx, bound));
    if (query.len == 0 or binding.matches(query, "字体 字号 行高 光标 font cursor font_family font_size font_weight line_height cursor_style")) try root.appendChild(cx.allocator, try fontSection(cx, bound));
    if (query.len == 0 or binding.matches(query, "终端 工作区 时间戳 侧栏 高亮 补全 timestamp_gutter sidebar_collapsed input_line_highlight completion enabled")) try root.appendChild(cx.allocator, try aidsSection(cx, bound));
    if (root.children.items.len == 0) try root.appendChild(cx.allocator, try ui.textStyled(cx, S.note, "没有匹配的设置"));
    return root;
}

fn themeSection(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const host = bound.hooks.appearance;
    const c = bound.controller;
    if (!c.theme_library.open) if (host) |h| if (h.library_dismissed) return dismissedTheme(cx, bound, h);
    var summary: [64]u8 = undefined;
    const title = if (c.theme_library.open) "主题库" else "主题";
    const record = if (host) |h| h.registry.get(c.model.value.ui.theme) else null;
    const selected_name = if (record) |r| r.theme.name else c.model.value.ui.theme;
    const section = try card(cx, bound, title, if (c.theme_library.open and host != null) try std.fmt.bufPrint(&summary, "{d} 个主题", .{host.?.registry.counts().all}) else selected_name, ui.icons.palette, 0, "settings.appearance.themes");
    const row = try ui.boxStyled(cx, S.materialRow, .{});
    row.style.gap = 8;
    row.meta.ownership.meta.test_id = "settings.theme.current";
    if (record) |r| try row.appendChild(cx.allocator, try thumbnail(cx, r));
    const name = try ui.textStyled(cx, S.label, if (record) |r| r.theme.name else c.model.value.ui.theme);
    textFill(name);
    try row.appendChild(cx.allocator, name);
    try row.appendChild(cx.allocator, try iconButton(cx, bound.scope, bound, .open_library, "", ui.icons.palette, "打开主题库", "settings.theme.library.open", 28, host == null or disabled(bound)));
    if (!std.mem.eql(u8, c.model.value.ui.theme, c.original.value.ui.theme)) try row.appendChild(cx.allocator, try previewBadge(cx, "预览中"));
    try row.appendChild(cx.allocator, try iconButton(cx, bound.scope, bound, .import_theme, "", ui.icons.upload, "导入 .itermcolors", "settings.theme.import", 28, host == null or disabled(bound)));
    if (c.theme_library.open) try row.appendChild(cx.allocator, try iconButton(cx, bound.scope, bound, .close_library, "", ui.icons.x, "关闭主题库，保留草稿与查询", "settings.theme.library.close", 28, false));
    try section.body.appendChild(cx.allocator, row);
    if (c.theme_library.open and host != null) {
        const grid = try ThemeGrid.mount(cx, bound, host.?);
        try section.body.appendChild(cx.allocator, grid.root);
    } else if (record) |r| try section.body.appendChild(cx.allocator, try miniPreview(cx, r, c.model.value.ui.timestamp_gutter, c.model.value.ui.input_line_highlight, c.model.value.ui.sidebar_collapsed));
    if (c.theme_library.problem) |problem| try section.body.appendChild(cx.allocator, try notice(cx, themeProblem(problem), true));
    return section.root;
}

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
        error.BuiltinThemeProtected => "内置主题不可移除",
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
    const text = try ui.textStyled(cx, S.label, label);
    textFill(text);
    try left.appendChild(cx.allocator, text);
    if (help) |message| {
        const tooltip = try ui.widgets.Tooltip(.{ .text = message, .open_delay_ms = 450 }).mount(bound.scope, cx);
        const button = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.circle_help, .icon_size = @as(f32, 14), .a11y_label = message, .variant = .ghost, .base_style = S.plainButton(22, 22, false) }).mount(bound.scope, cx);
        button.meta.ownership.meta.test_id = try id(bound.scope, "settings.help.", label);
        try tooltip.trigger.appendChild(cx.allocator, button);
        try left.appendChild(cx.allocator, tooltip.wrapper);
    }
    try row.appendChild(cx.allocator, left);
    try row.appendChild(cx.allocator, control);
    return row;
}

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
    const control_width: f32 = if (std.mem.eql(u8, key.key, "fit")) 176 else 164;
    const button = try choiceTrigger(cx, bound, shown, control_width, if (std.mem.eql(u8, key.key, "fit")) 32 else 30);
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

fn fontSection(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const c = bound.controller;
    var buffer: [256]u8 = undefined;
    const section = try card(cx, bound, "字体与排版", try std.fmt.bufPrint(&buffer, "{s} · {d} pt", .{ c.model.value.ui.font_family, c.model.value.ui.font_size }), ui.icons.type, 2, "settings.appearance.font");
    const custom = if (bound.hooks.appearance) |h| h.custom_font_edit else false;
    if (custom) {
        const field = try Field.create(cx, bound, .{ .section = "ui", .key = "font_family" }, 164, 30);
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
    const size = try Field.create(cx, bound, .{ .section = "ui", .key = "font_size" }, 164, 30);
    try section.body.appendChild(cx.allocator, try fieldRow(cx, bound, "字体大小", null, size.input.node));
    try section.body.appendChild(cx.allocator, size.error_box);
    const weight = try chooser(cx, bound, .{ .section = "ui", .key = "font_weight" }, c.model.value.ui.font_weight, &.{ .{ .label = "Light", .value = "light" }, .{ .label = "Regular", .value = "regular" }, .{ .label = "Medium", .value = "medium" }, .{ .label = "Bold", .value = "bold" } }, 220, 158, 10, 6, 30);
    try section.body.appendChild(cx.allocator, try fieldRow(cx, bound, "基准字重", "所选字体不支持此字重时，请选择其他字重后保存。", weight));
    const line = try Field.create(cx, bound, .{ .section = "ui", .key = "line_height" }, 164, 30);
    try section.body.appendChild(cx.allocator, try fieldRow(cx, bound, "行高倍率", null, line.input.node));
    try section.body.appendChild(cx.allocator, line.error_box);
    const cursor = try chooser(cx, bound, .{ .section = "ui", .key = "cursor_style" }, c.model.value.ui.cursor_style, &.{ .{ .label = "Block · 方块", .value = "block" }, .{ .label = "Bar · 竖线", .value = "bar" }, .{ .label = "Underline · 下划线", .value = "underline" } }, 220, 128, 10, 6, 32);
    try section.body.appendChild(cx.allocator, try fieldRow(cx, bound, "光标样式", null, cursor));
    const status = try ui.textStyled(cx, S.errorNote, "");
    status.meta.ownership.meta.test_id = "settings.font.status";
    bound.font_status_label = status;
    try section.body.appendChild(cx.allocator, status);
    bound.refreshFooter();
    return section.root;
}

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
    const section = try card(cx, bound, "终端与工作区", "", ui.icons.terminal, 3, "settings.appearance.aids");
    for ([_]struct { label: []const u8, key: binding.Key, help: ?[]const u8 }{
        .{ .label = "时间戳侧栏", .key = .{ .section = "ui", .key = "timestamp_gutter" }, .help = "显示输出时间，不包含在复制的终端内容中。" },
        .{ .label = "应用命令补全", .key = .{ .section = "completion", .key = "enabled" }, .help = null },
        .{ .label = "输入行相对高亮", .key = .{ .section = "ui", .key = "input_line_highlight" }, .help = null },
        .{ .label = "默认折叠侧栏", .key = .{ .section = "ui", .key = "sidebar_collapsed" }, .help = "保存手动偏好；窄窗口自动折叠不会覆盖它。" },
    }) |field| {
        const control = try ui.box(cx, .{ .width = .{ .px = 164 }, .height = .{ .px = 30 }, .direction = .row, .align_items = .center, .justify = .end, .padding = .{ .right = 10 }, .flex_shrink = 0 }, .{});
        try control.appendChild(cx.allocator, try toggle(cx, bound, field.key, field.label));
        try section.body.appendChild(cx.allocator, try fieldRow(cx, bound, field.label, field.help, control));
    }
    if (bound.hooks.appearance) |h| if (h.registry.get(bound.controller.model.value.ui.theme)) |record| try section.body.appendChild(cx.allocator, try miniPreview(cx, record, bound.controller.model.value.ui.timestamp_gutter, bound.controller.model.value.ui.input_line_highlight, bound.controller.model.value.ui.sidebar_collapsed));
    return section.root;
}

fn materialSection(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const c = bound.controller;
    const background = c.model.value.ui.materials.background;
    const root = try ui.boxStyled(cx, S.card, .{});
    root.meta.ownership.meta.test_id = "settings.appearance.materials";
    const header = try ui.boxStyled(cx, S.header, .{});
    const click = try Click.create(bound.scope, bound, .toggle, "");
    click.key = .{ .section = "ui.materials.background", .key = "enabled" };
    const heading = try ui.widgets.Button(.{ .a11y_label = "背景图片", .variant = .ghost, .disabled = disabled(bound), .on_click = cx.on(Click, click, Click.activate), .base_style = S.menuRow(28, false) }).mount(bound.scope, cx);
    heading.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .height = .{ .px = 28 }, .padding = .ZERO, .direction = .row, .align_items = .center, .justify = .start, .gap = 6, .background = ui.Color.TRANSPARENT });
    try heading.appendChild(cx.allocator, try icon(cx, ui.icons.image, S.theme.current().fg_2));
    const title = try ui.textStyled(cx, S.label, "背景图片");
    title.style.width = .{ .px = 150 };
    try heading.appendChild(cx.allocator, title);
    heading.meta.ownership.meta.test_id = "settings.materials.header";
    try header.appendChild(cx.allocator, heading);
    try header.appendChild(cx.allocator, try toggle(cx, bound, .{ .section = "ui.materials.background", .key = "enabled" }, "开启背景图片"));
    const chevron = try icon(cx, if (background.enabled) ui.icons.chevron_down else ui.icons.chevron_right, S.theme.current().fg_2);
    chevron.style.width = .{ .px = 14 };
    chevron.style.height = .{ .px = 14 };
    try header.appendChild(cx.allocator, chevron);
    try root.appendChild(cx.allocator, header);
    if (!background.enabled) return root;
    const image = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 60 }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0, .min_width = 0 }, .{});
    image.meta.ownership.meta.test_id = "settings.background.identity";
    const preview = try Click.create(bound.scope, bound, .preview_material, "");
    const preview_button = try ui.widgets.Button(.{ .a11y_label = "背景预览", .variant = .ghost, .disabled = background.path.len == 0 or bound.hooks.appearance == null or c.background.last_good == null, .on_click = cx.on(Click, preview, Click.activate), .base_style = S.plainButton(72, 48, false) }).mount(bound.scope, cx);
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
    try image.appendChild(cx.allocator, try iconButton(cx, bound.scope, bound, .choose_image, "", ui.icons.folder_open, if (path.len == 0) "选择背景图片" else "替换背景图片", "settings.background.choose", 32, bound.hooks.appearance == null or disabled(bound)));
    try image.appendChild(cx.allocator, try iconButton(cx, bound.scope, bound, .remove_image, "", ui.icons.trash, "移除背景图片", "settings.background.remove", 32, background.path.len == 0 or disabled(bound)));
    try root.appendChild(cx.allocator, image);
    const fit_row = try ui.boxStyled(cx, S.materialRow, .{});
    const fit_label = try ui.textStyled(cx, S.label, "图片适配");
    fit_label.style.width = .{ .px = 140 };
    fit_label.style.flex_shrink = 0;
    try fit_row.appendChild(cx.allocator, fit_label);
    const fit = try chooser(cx, bound, .{ .section = "ui.materials.background", .key = "fit" }, switch (background.fit) {
        .fill => "Fill",
        .fit => "Fit",
        .center => "Center",
        .tile => "Tile",
    }, &.{ .{ .label = "Fill · 填充", .value = "fill" }, .{ .label = "Fit · 适应", .value = "fit" }, .{ .label = "Center · 居中", .value = "center" }, .{ .label = "Tile · 平铺", .value = "tile" } }, 176, 148, 8, 4, 30);
    try fit_row.appendChild(cx.allocator, fit);
    const alignment_label = try ui.textStyled(cx, S.label, "对齐");
    alignment_label.style.width = .{ .px = 48 };
    alignment_label.style.flex_shrink = 0;
    try fit_row.appendChild(cx.allocator, alignment_label);
    try fit_row.appendChild(cx.allocator, try alignmentChooser(cx, bound));
    try root.appendChild(cx.allocator, fit_row);
    const sliders = try ui.boxStyled(cx, S.column, .{});
    const transparency = try sliderRow(cx, bound, "透明度", .{ .section = "ui.materials.background", .key = "transparency" }, background.transparency, 100, 0);
    const blur = try sliderRow(cx, bound, "模糊度", .{ .section = "ui.materials", .key = "blur_px" }, @floatFromInt(c.model.value.ui.materials.blur_px), 96, 1);
    try sliders.appendChild(cx.allocator, transparency.row);
    try sliders.appendChild(cx.allocator, blur.row);
    try root.appendChild(cx.allocator, sliders);
    try root.appendChild(cx.allocator, transparency.field.error_box);
    try root.appendChild(cx.allocator, blur.field.error_box);
    return root;
}

fn sliderRow(cx: *ui.Cx, bound: *binding.Binding, label: []const u8, key: binding.Key, value: f32, max: f32, step: f32) !struct { row: *ui.Node, field: *Field } {
    const row = try ui.boxStyled(cx, S.materialRow, .{});
    const labels = try ui.box(cx, .{ .width = .{ .px = 140 }, .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 }, .{});
    const name = try ui.textStyled(cx, S.label, label);
    textFill(name);
    try labels.appendChild(cx.allocator, name);
    const tip = try ui.widgets.Tooltip(.{ .text = if (step == 0) "图片透明度 0–100；100 完全透明，允许小数。" else "仅模糊背景图片；0–96 的整数，不影响文字与控件。", .open_delay_ms = 450 }).mount(bound.scope, cx);
    const help = try ui.widgets.Button(.{ .a11y_label = if (step == 0) "图片透明度说明" else "背景模糊度说明", .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.circle_help, .icon_size = @as(f32, 16), .base_style = S.plainButton(22, 22, false) }).mount(bound.scope, cx);
    help.meta.ownership.meta.test_id = try id(bound.scope, "settings.materials.help.", key.key);
    try tip.trigger.appendChild(cx.allocator, help);
    try labels.appendChild(cx.allocator, tip.wrapper);
    try row.appendChild(cx.allocator, labels);
    const signal = try bound.scope.createSignal(f32, value);
    const number = try Field.create(cx, bound, key, 100, 32);
    number.slider = signal;
    const slider = try bound.scope.allocator.create(SliderEdit);
    slider.* = .{ .field = number, .integer = step != 0 };
    try bound.scope.onCleanup(SliderEdit, slider, SliderEdit.cleanup);
    const result = try ui.widgets.Slider(.{ .value = signal, .min = @as(f32, 0), .max = max, .step = step, .width = @as(f32, 328), .track_height = @as(f32, 4), .thumb_size = @as(f32, 16), .disabled = disabled(bound), .on_change = cx.on(SliderEdit, slider, SliderEdit.change), .test_id = try id(bound.scope, "settings.slider.", key.key) }).mount(bound.scope, cx);
    result.wrapper.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .height = .{ .px = 32 }, .min_width = 0, .align_items = .center, .padding = .{ .left = 8, .right = 8 } });
    try row.appendChild(cx.allocator, result.wrapper);
    try row.appendChild(cx.allocator, number.input.node);
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
    const names = [3][3][]const u8{ .{ "左上", "上中", "右上" }, .{ "左中", "居中", "右中" }, .{ "左下", "下中", "右下" } };
    const x: @import("../background_asset.zig").Horizontal = background.alignment_x;
    const y: @import("../background_asset.zig").Vertical = background.alignment_y;
    const label = names[@backingInt(y)][@backingInt(x)];
    const trigger = try choiceTrigger(cx, bound, label, 198, 32);
    popover.wrapper.style.width = .{ .px = 198 };
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
    save.button.style.width = .{ .px = 32 };
    save.button.style.height = .{ .px = 32 };
    try root.appendChild(cx.allocator, save.wrapper);
    return root;
}
