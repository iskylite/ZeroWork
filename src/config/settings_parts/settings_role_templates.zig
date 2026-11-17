const std = @import("std");
const ui = @import("ui");
const binding = @import("../settings_content_view.zig");
const controls = @import("settings_controls.zig");
const templates = @import("../ai_role_templates.zig");
const providers = @import("../../ai/provider_config.zig");
const Effort = @import("../../ai/provider.zig").Effort;

const RowAction = struct {
    bound: *binding.Binding,
    index: ?usize,
    error_label: *ui.Node,
    kind: enum { create, edit, copy, remove, make_default, close },
    fn run(self: *RowAction) void {
        self.apply() catch |err| setError(self.bound, self.error_label, err);
    }
    fn apply(self: *RowAction) !void {
        const controller = self.bound.controller;
        const current = controller.model.value.ai.child_role_templates;
        if (controller.model.locked) return error.SettingsLocked;
        if (self.index) |index| if (index >= current.len) return error.InvalidRoleTemplate;
        var arena = std.heap.ArenaAllocator.init(controller.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var next: std.ArrayList(templates.Stored) = .empty;
        var editor: ?usize = null;
        switch (self.kind) {
            .close => {},
            .edit => editor = self.index,
            .create, .copy => {
                try next.appendSlice(a, current);
                var item: templates.Stored = if (self.index) |index| current[index] else .{ .name = "" };
                const base = if (self.kind == .copy) "模板副本" else "新模板";
                item.name = try uniqueName(a, current, base);
                item.is_default = false;
                try next.append(a, item);
                try controller.setRoleTemplates(next.items);
                editor = current.len;
            },
            .remove, .make_default => {
                for (current, 0..) |item, index| {
                    if (self.kind == .remove and self.index == index) continue;
                    var copy = item;
                    if (self.kind == .make_default) copy.is_default = self.index == index;
                    try next.append(a, copy);
                }
                try controller.setRoleTemplates(next.items);
            },
        }
        controller.role_template_editor = editor;
        self.bound.hooks.changed(self.bound.hooks.context);
    }
};

fn uniqueName(a: std.mem.Allocator, current: []const templates.Stored, base: []const u8) ![]const u8 {
    var suffix: usize = 1;
    while (true) : (suffix += 1) {
        const name = if (suffix == 1) base else try std.fmt.allocPrint(a, "{s} {d}", .{ base, suffix });
        for (current) |item| {
            if (std.mem.eql(u8, item.name, name)) break;
        } else return name;
    }
}
fn setError(bound: *binding.Binding, label: *ui.Node, err: anyerror) void {
    label.setDisplay(.flex);
    label.setTextContent(bound.cx.allocator, switch (err) {
        error.DuplicateRoleTemplate => "模板名称已存在",
        error.InvalidRoleTemplate => "请输入有效的模板名称",
        else => "无法更新模板",
    }) catch {};
    bound.cx.requestRedraw();
}

const Editor = struct {
    bound: *binding.Binding,
    index: usize,
    name: *ui.Signal([]const u8),
    models: [5]?*ui.Signal(?[]const u8) = @splat(null),
    efforts: [5]?*ui.Signal(?[]const u8) = @splat(null),
    choices: []const providers.ModelSelection,
    error_label: *ui.Node,

    fn apply(self: *Editor) void {
        self.save() catch |err| setError(self.bound, self.error_label, err);
    }
    fn save(self: *Editor) !void {
        const controller = self.bound.controller;
        const current = controller.model.value.ai.child_role_templates;
        if (self.index >= current.len) return error.InvalidRoleTemplate;
        const next = try controller.allocator.dupe(templates.Stored, current);
        defer controller.allocator.free(next);
        const item = &next[self.index];
        item.name = std.mem.trim(u8, self.name.peek(), " \t\r\n");
        for (1..5) |slot| {
            const encoded = self.models[slot].?.peek() orelse "inherit";
            if (std.mem.eql(u8, encoded, "inherit")) {
                item.models[slot] = null;
                item.providers[slot] = null;
            } else if (!std.mem.eql(u8, encoded, "unavailable")) {
                const index = std.fmt.parseInt(usize, encoded, 10) catch return error.InvalidRoleTemplate;
                if (index >= self.choices.len) return error.InvalidRoleTemplate;
                item.models[slot] = self.choices[index].model_id;
                item.providers[slot] = self.choices[index].provider_id;
            }
            item.efforts[slot] = std.meta.stringToEnum(Effort, self.efforts[slot].?.peek() orelse "inherit");
        }
        try controller.setRoleTemplates(next);
        controller.role_template_editor = null;
        self.bound.hooks.changed(self.bound.hooks.context);
    }
};

fn row(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{ .width = .fill(), .min_width = 0, .height = .{ .fit = .{} }, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .top = 3, .bottom = 3 }, .flex_shrink = 0 }, .{});
}
fn button(bound: *binding.Binding, parent: *ui.Node, label: []const u8, id: []const u8, handler: ui.Handler(void)) !void {
    const node = try ui.widgets.Button(.{ .label = label, .variant = .secondary, .on_click = handler }).mount(bound.scope, bound.cx);
    node.meta.ownership.meta.test_id = id;
    try parent.appendChild(bound.cx.allocator, node);
}
fn action(bound: *binding.Binding, parent: *ui.Node, error_label: *ui.Node, index: ?usize, kind: @FieldType(RowAction, "kind"), label: []const u8) !void {
    const state = try bound.scope.createState(RowAction, .{ .bound = bound, .index = index, .kind = kind, .error_label = error_label });
    const id = if (index) |i| try std.fmt.allocPrint(bound.scope.allocator, "settings.template.{s}.{d}", .{ @tagName(kind), i }) else try std.fmt.allocPrint(bound.scope.allocator, "settings.template.{s}", .{@tagName(kind)});
    try button(bound, parent, label, id, bound.cx.on(RowAction, state, RowAction.run));
}

pub fn mount(section: *controls.Section) !void {
    const bound = section.page.bound;
    const cx = bound.cx;
    const current = bound.controller.model.value.ai.child_role_templates;
    const active = templates.Stored.active(current);
    const error_label = try ui.textStyled(cx, controls.S.note, "");
    error_label.setDisplay(.none);
    try section.body.appendChild(cx.allocator, error_label);
    const built_in = try row(cx);
    try built_in.appendChild(cx.allocator, try ui.textStyled(cx, controls.S.note, "均衡"));
    try built_in.appendChild(cx.allocator, try ui.spacer(cx));
    if (active == null) {
        try built_in.appendChild(cx.allocator, try ui.textStyled(cx, controls.S.note, "默认"));
    } else try action(bound, built_in, error_label, null, .make_default, "设为默认");
    try section.body.appendChild(cx.allocator, built_in);
    for (current, 0..) |item, index| {
        const line = try row(cx);
        const title = try ui.textStyled(cx, controls.S.note, "");
        try title.setTextContent(cx.allocator, item.name);
        title.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0, .overflow_hidden = true });
        try line.appendChild(cx.allocator, title);
        if (item.is_default) {
            try line.appendChild(cx.allocator, try ui.textStyled(cx, controls.S.note, "默认"));
        } else try action(bound, line, error_label, index, .make_default, "设为默认");
        try action(bound, line, error_label, index, .edit, "编辑");
        try action(bound, line, error_label, index, .copy, "复制");
        try action(bound, line, error_label, index, .remove, "删除");
        try section.body.appendChild(cx.allocator, line);
        if (bound.controller.role_template_editor == index) try mountEditor(bound, section.body, item, index, error_label);
    }
    const actions = try row(cx);
    try action(bound, actions, error_label, null, .create, "新建模板");
    try section.body.appendChild(cx.allocator, actions);
}

fn mountEditor(bound: *binding.Binding, parent: *ui.Node, item: templates.Stored, index: usize, error_label: *ui.Node) !void {
    const cx = bound.cx;
    const a = bound.scope.allocator;
    const ai = bound.controller.model.value.ai;
    var models: std.ArrayList(providers.ModelSelection) = .empty;
    var options: std.ArrayList(ui.widgets.SelectOption) = .empty;
    try options.append(a, .{ .value = "inherit", .label = "继承会话模型" });
    for (ai.providers[0..@min(ai.provider_count, ai.providers.len)]) |provider| {
        if (!provider.enabled) continue;
        const provider_id = providers.providerId(provider);
        const legacy = [_]@import("../config.zig").AiModel{.{ .id = provider.model }};
        const configured = provider.models[0..@min(provider.model_count, provider.models.len)];
        const entries = if (configured.len == 0 and provider.model.len != 0) &legacy else configured;
        for (entries) |model| {
            const model_id = model.id;
            if (model_id.len == 0) continue;
            const value = try std.fmt.allocPrint(a, "{d}", .{models.items.len});
            const label = try std.fmt.allocPrint(a, "{s} · {s}", .{ model_id, provider_id });
            try models.append(a, .{ .provider_id = try a.dupe(u8, provider_id), .model_id = try a.dupe(u8, model_id) });
            try options.append(a, .{ .value = value, .label = label, .test_id = try std.fmt.allocPrint(a, "settings.template.model.option.{s}", .{value}) });
        }
    }
    const editor = try bound.scope.createState(Editor, .{ .bound = bound, .index = index, .name = try bound.scope.createText(item.name, .{ .capacity = 128 }), .choices = models.items, .error_label = error_label });
    const card = try ui.box(cx, .{ .width = .fill(), .direction = .column, .gap = 4, .padding = ui.Padding.all(8), .border = .{ .radius = 8 }, .background = controls.S.theme.popupInset() }, .{});
    card.meta.ownership.meta.test_id = "settings.template.editor";
    const field = try ui.widgets.Input(.{ .value = editor.name, .placeholder = "模板名称" }).mountResult(bound.scope, cx);
    @import("../../ui/app_theme.zig").styleInput(field);
    try bound.registerInput(field.state);
    field.input_container.meta.ownership.meta.test_id = "settings.template.name";
    try card.appendChild(cx.allocator, field.node);
    const names = [_][]const u8{ "协调者", "规划", "核验", "执行", "批处理" };
    const efforts: []const ui.widgets.SelectOption = &.{
        .{ .value = "inherit", .label = "自动推理强度" },
        .{ .value = "none", .label = "关闭" },
        .{ .value = "low", .label = "低" },
        .{ .value = "medium", .label = "中" },
        .{ .value = "high", .label = "高", .test_id = "settings.template.effort.high" },
        .{ .value = "xhigh", .label = "较高" },
        .{ .value = "max", .label = "最高" },
        .{ .value = "ultra", .label = "极高" },
    };
    for (1..5) |slot| {
        const line = try row(cx);
        const role = try ui.textStyled(cx, controls.S.note, names[slot]);
        role.setStyleInline(cx.allocator, .{ .width = .{ .px = 46 }, .flex_shrink = 0 });
        try line.appendChild(cx.allocator, role);
        const configured = item.selection(ai, @fromBackingInt(@intCast(slot)));
        var model_value: []const u8 = if (item.models[slot] == null) "inherit" else "unavailable";
        if (configured) |key| for (models.items, 0..) |choice, i| {
            if (choice.eql(key)) {
                model_value = options.items[i + 1].value;
                break;
            }
        };
        var choices = options;
        if (std.mem.eql(u8, model_value, "unavailable")) {
            choices = .empty;
            try choices.appendSlice(a, options.items);
            try choices.append(a, .{ .value = "unavailable", .label = try std.fmt.allocPrint(a, "{s}（不可用）", .{item.models[slot].?}) });
        }
        editor.models[slot] = try bound.scope.createSignal(?[]const u8, model_value);
        editor.efforts[slot] = try bound.scope.createSignal(?[]const u8, if (item.efforts[slot]) |value| @tagName(value) else "inherit");
        const model = try ui.widgets.Select(.{ .options = choices.items, .width = 216, .value = editor.models[slot].? }).mount(bound.scope, cx);
        model.trigger.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "settings.template.model.{d}", .{slot});
        const effort = try ui.widgets.Select(.{ .options = efforts, .width = 128, .value = editor.efforts[slot].? }).mount(bound.scope, cx);
        effort.trigger.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "settings.template.effort.{d}", .{slot});
        try line.appendChild(cx.allocator, model.wrapper);
        try line.appendChild(cx.allocator, effort.wrapper);
        try card.appendChild(cx.allocator, line);
    }
    const footer = try row(cx);
    try footer.appendChild(cx.allocator, try ui.spacer(cx));
    try action(bound, footer, error_label, null, .close, "取消");
    try button(bound, footer, "应用", "settings.template.apply", cx.on(Editor, editor, Editor.apply));
    try card.appendChild(cx.allocator, footer);
    try parent.appendChild(cx.allocator, card);
}
