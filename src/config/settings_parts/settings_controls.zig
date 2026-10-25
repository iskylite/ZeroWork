//! Shared native controls for the frozen V3 settings cards and field rows.
const std = @import("std");
const ui = @import("ui");
const binding = @import("../settings_content_view.zig");
const config = @import("../config.zig");
const values = @import("../settings_values.zig");
const schema = @import("../settings_schema.zig");
const window_policy = @import("../../transfer/window_policy.zig");
pub const S = @import("../settings_styles.zig");
pub const Key = binding.Key;
pub const Summary = *const fn (config.Config, []u8) anyerror![]const u8;
pub const Enabled = *const fn (config.Config) bool;

fn inputPresentation(key: Key, label: []const u8) struct { label: []const u8, unit: ?[]const u8 } {
    if (std.mem.eql(u8, key.section, "log") and std.mem.eql(u8, key.key, "retention_days")) return .{ .label = "保留天数", .unit = "天" };
    if (std.mem.lastIndexOf(u8, label, "（")) |start| {
        if (std.mem.endsWith(u8, label, "）")) return .{ .label = label[0..start], .unit = label[start + "（".len .. label.len - "）".len] };
    }
    return .{ .label = label, .unit = null };
}

/// Arrange the native Accordion parts once for every settings page. The title
/// and its description share a flexible column in either fold state.
pub fn sectionHeader(cx: *ui.Cx, scope: *ui.Scope, result: ui.widgets.AccordionItemResult, icon: ui.SvgAsset, expanded: bool, summary: []const u8, id: []const u8) !*ui.Node {
    result.item.setStyleInline(cx.allocator, S.sectionState(expanded));
    result.header.setStyleInline(cx.allocator, S.summaryHeader(summary.len != 0));

    result.header.removeChild(result.chevron);
    result.header.removeChild(result.title);
    try result.header.appendChild(cx.allocator, try ui.iconTintStyled(cx, icon, S.theme.current().fg_2, S.sectionIcon(undefined)));
    const heading = try ui.boxStyled(cx, S.sectionHeading, .{});
    try result.header.appendChild(cx.allocator, heading);
    result.title.setStyleInline(cx.allocator, S.sectionTitle(undefined));
    if (result.title.getText()) |old| {
        var text = old;
        text.font_size = 13;
        text.font_weight = 650;
        text.line_height = 20.0 / 13.0;
        text.color = S.theme.current().fg_1;
        result.title.setText(text);
    }
    try heading.appendChild(cx.allocator, result.title);
    const summary_node = try ui.textStyled(cx, S.sectionSummary, try owned(scope, summary));
    summary_node.style.width = .fill();
    summary_node.setStyleInline(cx.allocator, .{ .min_width = 0 });
    summary_node.setDisplay(if (summary.len != 0) .flex else .none);
    summary_node.meta.ownership.meta.test_id = try stableId(scope, id, ".summary");
    try heading.appendChild(cx.allocator, summary_node);
    result.chevron.setStyleInline(cx.allocator, S.sectionChevron(undefined));
    try result.header.appendChild(cx.allocator, result.chevron);
    return summary_node;
}

pub fn owned(scope: *ui.Scope, text: []const u8) ![]const u8 {
    const Owner = struct {
        allocator: std.mem.Allocator,
        value: []u8,
        fn cleanup(self: *@This()) void {
            self.allocator.free(self.value);
            self.allocator.destroy(self);
        }
    };
    const owner = try scope.allocator.create(Owner);
    errdefer scope.allocator.destroy(owner);
    owner.* = .{ .allocator = scope.allocator, .value = try scope.allocator.dupe(u8, text) };
    errdefer scope.allocator.free(owner.value);
    try scope.onCleanup(Owner, owner, Owner.cleanup);
    return owner.value;
}

pub fn stableId(scope: *ui.Scope, prefix: []const u8, suffix: []const u8) ![]const u8 {
    const value = try std.fmt.allocPrint(scope.allocator, "{s}{s}", .{ prefix, suffix });
    defer scope.allocator.free(value);
    return owned(scope, value);
}

pub const Page = struct {
    bound: *binding.Binding,
    cx: *ui.Cx,
    root: *ui.Node,
    fields: std.ArrayList(*Field) = .empty,
    sections: std.ArrayList(*Section) = .empty,
    fixed_controls: std.ArrayList(*ui.Node) = .empty,

    pub fn create(cx: *ui.Cx, bound: *binding.Binding, id: []const u8) !*Page {
        const self = try bound.scope.allocator.create(Page);
        self.* = .{ .bound = bound, .cx = cx, .root = try ui.boxStyled(cx, S.sectionColumn, .{}) };
        try bound.scope.onCleanup(Page, self, Page.cleanup);
        self.root.meta.ownership.meta.test_id = id;
        try cx.addAfterLayoutHook(self, Page.afterLayout);
        try bound.scope.createEffect(.{ .page = self }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.page.bound.saving.get();
                for (ctx.page.fields.items) |field| field.refresh();
                for (ctx.page.sections.items) |item| item.refresh();
            }
        }.run);
        return self;
    }
    fn cleanup(self: *Page) void {
        self.cx.removeAfterLayoutHook(self);
        self.fields.deinit(self.bound.scope.allocator);
        self.sections.deinit(self.bound.scope.allocator);
        self.fixed_controls.deinit(self.bound.scope.allocator);
        self.bound.scope.allocator.destroy(self);
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Page = @ptrCast(@alignCast(raw));
        const width: f32 = if (self.cx.viewport.width <= 900) 210 else 220;
        var changed = false;
        for (self.fields.items) |field| {
            if (field.checked != null or field.control == null) continue;
            const outer = field.row.children.items[field.row.children.items.len - 1];
            const inner = if (field.input_result) |input| input.input_container else field.control.?;
            for ([_]*ui.Node{ outer, field.control.?, inner }) |node| {
                if (node.style.width != .px or node.style.width.px != width) {
                    node.setStyleInline(self.cx.allocator, .{ .width = .{ .px = width }, .flex_shrink = 0 });
                    changed = true;
                }
            }
        }
        for (self.fixed_controls.items) |node| {
            if (node.style.width != .px or node.style.width.px != width) {
                node.setStyleInline(self.cx.allocator, .{ .width = .{ .px = width }, .flex_shrink = 0 });
                changed = true;
            }
        }
        return if (changed) .needs_layout else .done;
    }
    pub fn refresh(self: *Page) void {
        for (self.fields.items) |field| field.refresh();
        for (self.sections.items) |item| item.refresh();
        self.bound.valuesChanged();
    }
    fn actionState(self: *Page, action: binding.Action) binding.ActionState {
        return if (self.bound.hooks.action_state) |read| read(self.bound.hooks.context, action) else .{};
    }
    pub fn section(self: *Page, title: []const u8, description: []const u8, icon: ui.SvgAsset, bit: u6, id: []const u8, summary: ?Summary) !*Section {
        const self_section = try self.bound.scope.allocator.create(Section);
        self_section.* = .{ .page = self, .bit = bit, .root = undefined, .body = undefined, .header = undefined, .expanded = undefined, .summary = summary, .description = description, .title = title, .summary_node = undefined };
        try self.bound.scope.onCleanup(Section, self_section, Section.cleanup);
        const query = self.bound.controller.search_query;
        const expanded = query.len != 0 or self.bound.controller.folded_sections & (@as(u64, 1) << bit) == 0;
        self_section.expanded = try self.bound.scope.createSignal(bool, expanded);
        const result = try ui.widgets.AccordionItem(.{ .title = title, .expanded = ui.split(self_section.expanded, self.cx.on(Section, self_section, Section.fold)), .variant = .ghost }).mount(self.bound.scope, self.cx);
        self_section.root = result.item;
        self_section.body = result.body;
        self_section.header = result.header;
        self_section.summary_node = try sectionHeader(self.cx, self.bound.scope, result, icon, expanded, description, id);
        result.item.meta.ownership.meta.test_id = id;
        result.header.meta.ownership.meta.test_id = try stableId(self.bound.scope, id, ".header");
        if (self.bound.controller.state() == .saving) {
            result.header.behavior.events.on_event = null;
            result.header.setFocusable(false);
        }
        result.body.setStyleInline(self.cx.allocator, S.column(undefined));
        result.body.style.padding = .{ .left = 16, .right = 16, .bottom = 8 };
        result.body.style.gap = 0;
        try self.root.appendChild(self.cx.allocator, result.item);
        try self.sections.append(self.bound.scope.allocator, self_section);
        self_section.refresh();
        return self_section;
    }
    pub fn finish(self: *Page) !*ui.Node {
        for (self.sections.items) |item| item.refresh();
        if (self.root.children.items.len == 0) try self.root.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.note, "没有匹配的设置"));
        return self.root;
    }
};

pub const Section = struct {
    page: *Page,
    bit: u6,
    root: *ui.Node,
    body: *ui.Node,
    header: *ui.Node,
    expanded: *ui.Signal(bool),
    summary: ?Summary,
    description: []const u8,
    title: []const u8,
    summary_node: *ui.Node,
    fn cleanup(self: *Section) void {
        self.page.bound.scope.allocator.destroy(self);
    }
    fn fold(self: *Section, open: bool) void {
        const bound = self.page.bound;
        if (bound.controller.state() == .saving or bound.controller.search_query.len != 0) return;
        self.expanded.set(open);
        const mask = @as(u64, 1) << self.bit;
        if (open) bound.controller.folded_sections &= ~mask else bound.controller.folded_sections |= mask;
        bound.hooks.changed(bound.hooks.context);
    }
    fn refresh(self: *Section) void {
        var buffer: [512]u8 = undefined;
        const text = if (self.summary) |render| render(self.page.bound.controller.model.value, &buffer) catch self.description else self.description;
        self.summary_node.setTextContent(self.page.cx.allocator, text) catch {};
        const expanded = self.expanded.peek();
        self.summary_node.setDisplay(if (text.len != 0) .flex else .none);
        self.header.setStyleInline(self.page.cx.allocator, S.summaryHeader(text.len != 0));
        self.root.setStyleInline(self.page.cx.allocator, S.sectionState(expanded));

        const saving = self.page.bound.controller.state() == .saving;
        self.header.setFocusable(!saving);
        if (self.header.behavior.interaction.a11y) |*a11y| a11y.disabled = saving;
    }
    pub fn matches(self: *Section, terms: []const u8) bool {
        return binding.matches(self.page.bound.controller.search_query, terms);
    }
    fn matchesField(self: *Section, label: []const u8, key: []const u8, help: []const u8) bool {
        const query = self.page.bound.controller.search_query;
        return binding.matches(query, self.title) or binding.matches(query, self.description) or binding.matches(query, label) or binding.matches(query, key) or binding.matches(query, help);
    }
    pub fn input(self: *Section, key: Key, label: []const u8, help: []const u8, enabled: ?Enabled) !void {
        if (!self.matchesField(label, key.key, help)) return;
        const presentation = inputPresentation(key, label);
        const field = try Field.create(self.page, key, presentation.label, help, enabled);
        var buffer: [512]u8 = undefined;
        const raw = self.page.bound.controller.raw_fields[schema.find(key.section, key.key).?].input;
        field.text = try self.page.bound.scope.createText(raw orelse try valueText(self.page.bound.controller.model.value, key, &buffer), .{});
        field.input_result = try ui.widgets.Input(.{ .value = field.text.?, .append_text = presentation.unit, .disabled = field.disabled, .on_change = self.page.cx.on(Field, field, Field.edit), .on_submit = self.page.cx.on(Field, field, Field.submit) }).mountResult(self.page.bound.scope, self.page.cx);
        const result = &field.input_result.?;
        result.input_container.setStyleInline(self.page.cx.allocator, S.fieldControl(undefined));
        result.node.style.width = .{ .px = S.geometry.control_width };
        result.node.style.flex_shrink = 0;
        S.tuneInput(result);
        result.input_container.meta.ownership.meta.test_id = try stableId(self.page.bound.scope, "settings.field.", key.key);
        result.input_container.behavior.events.on_event_capture = Field.onEvent;
        result.input_container.behavior.events.capture_context = field;
        try self.page.bound.registerInput(result.state);
        try self.page.bound.registerEscape(result.state, field, Field.escapeFromHost);
        field.control = result.node;
        try field.row.appendChild(self.page.cx.allocator, result.node);
        try self.body.appendChild(self.page.cx.allocator, field.root);
        field.refresh();
    }
    pub fn toggle(self: *Section, key: Key, label: []const u8, help: []const u8, enabled: ?Enabled) !void {
        if (!self.matchesField(label, key.key, help)) return;
        const field = try Field.create(self.page, key, label, help, enabled);
        field.checked = try self.page.bound.scope.createSignal(bool, values.read(self.page.bound.controller.model.value, key.section, key.key).?.boolean);
        const node = try ui.widgets.Switch(.{ .checked = field.checked.?, .disabled = field.disabled, .on_change = self.page.cx.on(Field, field, Field.toggle) }).mount(self.page.bound.scope, self.page.cx);
        node.meta.ownership.meta.test_id = try stableId(self.page.bound.scope, "settings.field.", key.key);
        if (node.behavior.interaction.a11y) |*a11y| a11y.label = label;
        field.control = node;
        try field.row.appendChild(self.page.cx.allocator, node);
        try self.body.appendChild(self.page.cx.allocator, field.root);
        try self.page.bound.scope.createEffect(.{ .field = field }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.field.checked.?.get();
                S.paintSwitch(ctx.field.page.cx, ctx.field.control.?, ctx.field.checked.?.peek());
            }
        }.run);
        field.refresh();
    }
    pub fn select(self: *Section, key: Key, label: []const u8, help: []const u8, options: []const ui.widgets.SelectOption, enabled: ?Enabled) !void {
        if (!self.matchesField(label, key.key, help)) return;
        const field = try Field.create(self.page, key, label, help, enabled);
        field.selected = try self.page.bound.scope.createSignal(?[]const u8, try owned(self.page.bound.scope, values.read(self.page.bound.controller.model.value, key.section, key.key).?.text));
        const result = try ui.widgets.Select(.{ .options = options, .value = field.selected.?, .width = S.geometry.control_width, .disabled = field.disabled, .on_change = self.page.cx.on(Field, field, Field.select) }).mount(self.page.bound.scope, self.page.cx);
        result.wrapper.style.width = .{ .px = S.geometry.control_width };
        result.wrapper.style.flex_shrink = 0;
        result.trigger.setStyleInline(self.page.cx.allocator, S.fieldControl(undefined));
        if (result.trigger.parent) |trigger_owner| trigger_owner.setStyleInline(self.page.cx.allocator, .{ .width = .fill(), .min_width = 0 });
        result.trigger.meta.ownership.meta.test_id = try stableId(self.page.bound.scope, "settings.field.", key.key);
        result.content_slot.setStyleInline(self.page.cx.allocator, .{ .font_size = 11.5, .font_weight = 400 });
        field.control = result.trigger;
        field.select_result = result;
        if (result.open) |open| try self.page.bound.registerTooltip(open);
        try field.row.appendChild(self.page.cx.allocator, result.wrapper);
        try self.body.appendChild(self.page.cx.allocator, field.root);
        try self.page.bound.scope.createEffect(.{ .field = field }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.field.selected.?.get();
                S.tuneSelect(ctx.field.select_result.?);
            }
        }.run);
        field.refresh();
    }
    pub fn button(self: *Section, label: []const u8, value: []const u8, id: []const u8, action: binding.Action) !void {
        if (!self.matchesField(label, id, "")) return;
        const row = try plainRow(self.page.cx, label);
        const click = try self.page.bound.scope.allocator.create(ActionClick);
        click.* = .{ .page = self.page, .action = action };
        try self.page.bound.scope.onCleanup(ActionClick, click, ActionClick.cleanup);
        const state = self.page.actionState(action);
        const node = try ui.widgets.Button(.{ .label = try owned(self.page.bound.scope, value), .variant = .secondary, .disabled = self.page.bound.controller.state() == .saving or !state.enabled, .on_click = self.page.cx.on(ActionClick, click, ActionClick.run), .base_style = S.actionControl(false), .hover_style = S.buttonHover() }).mount(self.page.bound.scope, self.page.cx);
        node.meta.ownership.meta.test_id = id;
        try row.appendChild(self.page.cx.allocator, node);
        try self.body.appendChild(self.page.cx.allocator, row);
    }
    pub fn iconAction(self: *Section, label: []const u8, action_label: []const u8, icon: ui.SvgAsset, id: []const u8, action: binding.Action) !void {
        if (!self.matchesField(label, id, action_label)) return;
        const row = try plainRow(self.page.cx, label);
        const click = try self.page.bound.scope.allocator.create(ActionClick);
        click.* = .{ .page = self.page, .action = action };
        try self.page.bound.scope.onCleanup(ActionClick, click, ActionClick.cleanup);
        const state = self.page.actionState(action);
        const tip = try ui.widgets.Tooltip(.{ .text = state.reason orelse label, .open_delay_ms = 450 }).mount(self.page.bound.scope, self.page.cx);
        const node = try ui.widgets.Button(.{ .label = action_label, .icon_asset = icon, .icon_size = @as(f32, 14), .a11y_label = state.reason orelse action_label, .variant = .secondary, .disabled = self.page.bound.controller.state() == .saving or !state.enabled, .on_click = self.page.cx.on(ActionClick, click, ActionClick.run), .base_style = S.actionControl(action == .clear_logs or action == .clear_all), .hover_style = S.buttonHover() }).mount(self.page.bound.scope, self.page.cx);
        node.meta.ownership.meta.test_id = id;
        try tip.trigger.appendChild(self.page.cx.allocator, node);
        try row.appendChild(self.page.cx.allocator, tip.wrapper);
        try self.body.appendChild(self.page.cx.allocator, row);
    }
    pub fn directory(self: *Section, key: Key, label: []const u8) !void {
        if (!self.matchesField(label, key.key, "")) return;
        const row = try plainRow(self.page.cx, label);
        const click = try self.page.bound.scope.allocator.create(DirectoryClick);
        click.* = .{ .page = self.page, .key = key };
        try self.page.bound.scope.onCleanup(DirectoryClick, click, DirectoryClick.cleanup);
        const path = values.read(self.page.bound.controller.model.value, key.section, key.key).?.text;
        const node = try ui.widgets.Button(.{ .label = try owned(self.page.bound.scope, path), .icon_asset = ui.icons.folder, .variant = .secondary, .disabled = self.page.bound.controller.state() == .saving, .on_click = self.page.cx.on(DirectoryClick, click, DirectoryClick.run), .base_style = S.fieldButton(), .hover_style = S.buttonHover() }).mount(self.page.bound.scope, self.page.cx);
        click.node = node;
        try self.page.fixed_controls.append(self.page.bound.scope.allocator, node);
        node.meta.ownership.meta.test_id = try stableId(self.page.bound.scope, "settings.field.", key.key);
        try row.appendChild(self.page.cx.allocator, node);
        try self.body.appendChild(self.page.cx.allocator, row);
    }
    pub fn readonly(self: *Section, label: []const u8, value: []const u8) !void {
        if (!self.matchesField(label, "", "")) return;
        const row = try plainRow(self.page.cx, label);
        var style = S.value(undefined);
        style.wrap = .word;
        style.text_align = .end;
        const text = try ui.text(self.page.cx, try owned(self.page.bound.scope, value), style);
        text.setStyleInline(self.page.cx.allocator, .{ .width = .{ .px = 220 }, .flex_shrink = 0, .min_width = 0 });
        try self.page.fixed_controls.append(self.page.bound.scope.allocator, text);
        try row.appendChild(self.page.cx.allocator, text);
        try self.body.appendChild(self.page.cx.allocator, row);
    }
};

fn plainRow(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const row = try ui.boxStyled(cx, S.fieldRow, .{});
    const name = try ui.textStyled(cx, S.label, label);
    name.style.width = .fill();
    name.style.flex = 1;
    try row.appendChild(cx.allocator, name);
    return row;
}

const Field = struct {
    page: *Page,
    key: Key,
    root: *ui.Node,
    row: *ui.Node,
    error_label: *ui.Node,
    disabled: *ui.Signal(bool),
    enabled: ?Enabled,
    control: ?*ui.Node = null,
    input_result: ?ui.widgets.input.InputResult = null,
    text: ?*ui.Signal([]const u8) = null,
    checked: ?*ui.Signal(bool) = null,
    selected: ?*ui.Signal(?[]const u8) = null,
    select_result: ?ui.widgets.SelectResult = null,
    fn create(page: *Page, key: Key, label: []const u8, help: []const u8, enabled: ?Enabled) !*Field {
        const self = try page.bound.scope.allocator.create(Field);
        self.* = .{ .page = page, .key = key, .enabled = enabled, .disabled = try page.bound.scope.createSignal(bool, false), .root = try ui.boxStyled(page.cx, S.column, .{}), .row = try ui.boxStyled(page.cx, S.fieldRow, .{}), .error_label = try ui.textStyled(page.cx, S.errorNote, "") };
        try page.bound.scope.onCleanup(Field, self, Field.cleanup);
        self.root.style.gap = 1;
        self.root.meta.ownership.meta.test_id = try stableId(page.bound.scope, "settings.row.", key.key);
        self.error_label.meta.ownership.meta.test_id = try stableId(page.bound.scope, "settings.error.", key.key);
        const labels = try ui.boxStyled(page.cx, S.fieldLabel, .{});
        const title = try ui.textStyled(page.cx, S.label, label);
        title.style.width = .fill();
        title.style.flex = 1;
        try labels.appendChild(page.cx.allocator, title);
        if (help.len != 0) {
            const detail = try ui.textStyled(page.cx, S.sectionSummary, try owned(page.bound.scope, help));
            detail.style.width = .fill();
            detail.setStyleInline(page.cx.allocator, .{ .max_width = 360 });
            detail.meta.ownership.meta.test_id = try stableId(page.bound.scope, "settings.help.content.", key.key);
            try labels.appendChild(page.cx.allocator, detail);
        }
        try self.row.appendChild(page.cx.allocator, labels);
        try self.root.appendChild(page.cx.allocator, self.row);
        try self.root.appendChild(page.cx.allocator, self.error_label);
        try page.fields.append(page.bound.scope.allocator, self);
        return self;
    }
    fn cleanup(self: *Field) void {
        self.page.bound.scope.allocator.destroy(self);
    }
    fn refresh(self: *Field) void {
        const controller = self.page.bound.controller;
        const unavailable = controller.state() == .saving or if (self.enabled) |enabled| !enabled(controller.model.value) else false;
        self.disabled.set(unavailable);
        const problem = controller.fieldProblem(schema.find(self.key.section, self.key.key).?);
        self.error_label.setDisplay(if (problem != null) .flex else .none);
        self.error_label.setTextContent(self.page.cx.allocator, if (problem) |err| problemText(self.key, err) else "") catch {};
        if (self.input_result) |input| {
            input.input_container.setBorderWidth(0);
            input.input_container.setBackground(if (problem != null) S.theme.current().danger.withAlpha(23) else S.theme.current().well);
            input.input_container.setBorderColor(ui.Color.TRANSPARENT);
        }
    }
    fn edit(self: *Field, text: []const u8) void {
        if (self.disabled.peek()) return;
        self.page.bound.controller.editRaw(self.key.section, self.key.key, text) catch {};
        self.page.refresh();
    }
    fn submit(self: *Field, text: []const u8) void {
        if (self.input_result.?.state.imeIsComposing()) return;
        self.edit(text);
    }
    fn toggle(self: *Field, checked: bool) void {
        if (self.disabled.peek()) return;
        if (self.page.bound.hooks.edit) |edit_hook| edit_hook(self.page.bound.hooks.context, self.key, .{ .boolean = checked }) else self.page.bound.controller.editKey(self.key.section, self.key.key, .{ .boolean = checked }) catch {};
        self.page.refresh();
    }
    fn select(self: *Field, selected: ?[]const u8) void {
        if (self.disabled.peek()) return;
        const text = selected orelse return;
        if (std.mem.eql(u8, text, "__custom")) {
            self.selected.?.set(owned(self.page.bound.scope, values.read(self.page.bound.controller.model.value, self.key.section, self.key.key).?.text) catch return);
            self.page.bound.hooks.request_edit(self.page.bound.hooks.context, self.key, self.control.?);
            return;
        }
        self.page.bound.controller.editKey(self.key.section, self.key.key, .{ .text = text }) catch {};
        self.page.refresh();
    }
    fn escape(self: *Field) void {
        const current = values.read(self.page.bound.controller.model.value, self.key.section, self.key.key) orelse return;
        var buffer: [512]u8 = undefined;
        const text = valueText(self.page.bound.controller.model.value, self.key, &buffer) catch return;
        self.page.bound.controller.editKey(self.key.section, self.key.key, if (std.mem.eql(u8, self.key.key, "reconnect_backoff")) .{ .text = text } else current) catch return;
        self.text.?.set(text);
        self.page.refresh();
    }
    fn escapeFromHost(raw: *anyopaque) void {
        const self: *Field = @ptrCast(@alignCast(raw));
        self.escape();
    }
    fn onEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Field = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event != .key_down or self.input_result.?.state.imeIsComposing()) return .ignored;
        if (event.key_down.key == .escape) {
            self.escape();
            return .stop;
        }
        return .ignored;
    }
};

pub fn valueText(value: config.Config, key: Key, buffer: []u8) ![]const u8 {
    if (std.mem.eql(u8, key.section, "ssh") and std.mem.eql(u8, key.key, "reconnect_backoff")) {
        const sequence = value.ssh.reconnect_backoff;
        return std.fmt.bufPrint(buffer, "{d}, {d}, {d}, {d}, {d}", .{ sequence[0], sequence[1], sequence[2], sequence[3], sequence[4] });
    }
    return switch (values.read(value, key.section, key.key) orelse return error.UnknownKey) {
        .text => |text| text,
        .unsigned => |number| std.fmt.bufPrint(buffer, "{d}", .{number}),
        .decimal => |number| std.fmt.bufPrint(buffer, "{d}", .{number}),
        .boolean => error.InvalidType,
    };
}
fn problemText(key: Key, problem: anyerror) []const u8 {
    if (problem == error.TransferWindowBudgetExceeded) return std.fmt.comptimePrint("单任务窗口超过 {d} MiB，请减小分块大小或窗口分块数", .{window_policy.max_job_window_bytes / (1024 * 1024)});
    if (problem == error.TransferGlobalWindowBudgetExceeded) return std.fmt.comptimePrint("并发窗口总量超过 {d} MiB，请减小分块大小、窗口分块数或并发任务数", .{window_policy.max_global_window_bytes / (1024 * 1024)});
    if (problem == error.TransferWindowOverflow) return "传输窗口总量溢出，请减小分块大小、窗口分块数或并发任务数";
    if (std.mem.eql(u8, key.key, "reconnect_backoff")) return "请输入 5 个 0–255 整数，例如 [1,2,4,8,16]";
    if (std.mem.eql(u8, key.key, "reconnect_max")) return "请输入 0–5 的整数";
    if (std.mem.eql(u8, key.key, "quiet_hours")) return "请输入有效时段，例如 22:00-08:00";
    if (std.mem.eql(u8, key.key, "shared_pacing_kbps")) return "请输入 0–4294967295 的整数";
    if (std.mem.eql(u8, key.key, "window_chunks") or std.mem.eql(u8, key.key, "max_tasks")) return "请输入 1–255 的整数";
    if (std.mem.eql(u8, key.key, "term")) return "终端类型不能为空";
    return "请输入 1–65535 的整数";
}
const Help = struct {
    page: *Page,
    open: *ui.Signal(bool),
    fn cleanup(self: *Help) void {
        self.page.bound.scope.allocator.destroy(self);
    }
    fn focus(raw: *anyopaque) void {
        const self: *Help = @ptrCast(@alignCast(raw));
        self.open.set(true);
    }
    fn blur(raw: *anyopaque) void {
        const self: *Help = @ptrCast(@alignCast(raw));
        self.open.set(false);
    }
};
fn helpButton(page: *Page, key: Key, text: []const u8) !*ui.Node {
    const open = try page.bound.scope.createSignal(bool, false);
    const tip = try ui.widgets.Tooltip(.{ .text = text, .open = open, .position = .top, .open_delay_ms = 450, .background = S.theme.current().overlay, .text_color = S.theme.current().fg_1, .font_size = 10.5 }).mount(page.bound.scope, page.cx);
    tip.content.setStyleInline(page.cx.allocator, S.fieldHelp(undefined));
    tip.content.meta.ownership.meta.test_id = try stableId(page.bound.scope, "settings.help.content.", key.key);
    for (tip.content.children.items) |label| if (label.getText()) |old| {
        var props = old;
        props.wrap = .word;
        props.line_height = 16.0 / 10.5;
        label.setText(props);
        label.style.width = .fill();
    };
    const node = try ui.widgets.Button(.{ .icon_asset = ui.icons.circle_help, .icon_only = true, .icon_size = @as(f32, 16), .a11y_label = text, .variant = .ghost, .disabled = page.bound.controller.state() == .saving, .base_style = S.fieldHelpButton(), .hover_style = S.buttonHover() }).mount(page.bound.scope, page.cx);
    node.meta.ownership.meta.test_id = try stableId(page.bound.scope, "settings.help.", key.key);
    const focus = try page.bound.scope.allocator.create(Help);
    focus.* = .{ .page = page, .open = open };
    try page.bound.scope.onCleanup(Help, focus, Help.cleanup);
    node.behavior.events.on_focus = .{ .callback = Help.focus, .context = focus };
    node.behavior.events.on_blur = .{ .callback = Help.blur, .context = focus };
    try page.bound.registerTooltip(open);
    try tip.trigger.appendChild(page.cx.allocator, node);
    return tip.wrapper;
}
const ActionClick = struct {
    page: *Page,
    action: binding.Action,
    fn cleanup(self: *ActionClick) void {
        self.page.bound.scope.allocator.destroy(self);
    }
    fn run(self: *ActionClick) void {
        if (self.page.bound.controller.state() == .saving or !self.page.actionState(self.action).enabled) return;
        self.page.bound.hooks.action(self.page.bound.hooks.context, self.action);
    }
};
const DirectoryClick = struct {
    page: *Page,
    key: Key,
    node: *ui.Node = undefined,
    fn cleanup(self: *DirectoryClick) void {
        self.page.bound.scope.allocator.destroy(self);
    }
    fn run(self: *DirectoryClick) void {
        if (self.page.bound.controller.state() == .saving) return;
        self.page.bound.hooks.request_edit(self.page.bound.hooks.context, self.key, self.node);
    }
};
