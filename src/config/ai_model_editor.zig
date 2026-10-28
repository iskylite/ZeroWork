//! V3 model dialog. Edits remain local until the explicit commit callback.
const std = @import("std");
const ui = @import("ui");
const config = @import("config.zig");
const draft = @import("settings_ai_draft.zig");
const S = @import("settings_styles.zig");
const controls = @import("settings_parts/settings_controls.zig");

pub const Hooks = struct {
    context: *anyopaque,
    commit: *const fn (*anyopaque, usize, ?usize, config.AiModel) anyerror!void,
    fetch_models: *const fn (*anyopaque, usize) void,
    test_model: *const fn (*anyopaque, usize, config.AiModel) void,
    metadata: *const fn (*anyopaque, []const u8) ?@import("../ai/model_discovery.zig").ModelMetadata,
};
pub const Editor = struct {
    scope: *ui.Scope,
    cx: *ui.Cx,
    hooks: Hooks,
    provider: usize,
    index: ?usize,
    model: config.AiModel,
    open: *ui.Signal(bool),
    id: *ui.Signal([]const u8),
    context: *ui.Signal([]const u8),
    error_text: *ui.Signal([]const u8),
    modal: ui.widgets.ModalResult,
    inputs: [2]ui.widgets.input.InputResult = undefined,
    done: bool = false,
    efforts: [7]*ui.Signal(bool) = undefined,
    effort_body: *ui.Node = undefined,
    candidates: []const config.AiModel = &.{},
    capability_values: [2]?*ui.Signal(?[]const u8) = @splat(null),
    select_open: [3]?*ui.Signal(bool) = @splat(null),
    checks: [8]?*ui.Node = @splat(null),
    catalog_label: ?*ui.Node = null,
    catalog_query: ?*ui.Signal([]const u8) = null,
    catalog_rows: std.ArrayList(*ui.Node) = .empty,
    catalog_active: ?usize = null,
    catalog_custom: ?*ui.Node = null,
    capability_known: [2]bool = @splat(false),
    capability_sources: [2]?*SourceIndicator = @splat(null),
    catalog_popup: ?ui.widgets.popover.PopoverResult = null,
    catalog_options: ?*ui.Node = null,
    catalog_scroll: ?ui.widgets.ScrollAreaResult = null,
    catalog_status: ?*ui.Node = null,
    catalog_fetch: ?*ui.Node = null,
    test_status: ?*ui.Node = null,
    test_button: ?*ui.Node = null,
    test_signature: ?u64 = null,
    context_source: ?*SourceIndicator = null,
    save_button: ?*ui.Node = null,

    pub fn mount(cx: *ui.Cx, parent: *ui.Scope, provider: usize, index: ?usize, name: []const u8, model: config.AiModel, candidates: []const config.AiModel, hooks: Hooks) !*Editor {
        const scope = try parent.childScope();
        errdefer scope.dispose();
        const self = try scope.allocator.create(Editor);
        var buffer: [32]u8 = undefined;
        self.* = .{ .scope = scope, .cx = cx, .hooks = hooks, .provider = provider, .index = index, .model = model, .open = try scope.createSignal(bool, true), .id = try scope.createText(model.id, .{}), .context = try scope.createText(if (model.context_window == 0) "" else try std.fmt.bufPrint(&buffer, "{d}", .{model.context_window}), .{}), .error_text = try scope.createText("", .{}), .modal = undefined };
        self.capability_known = @splat(index != null);
        self.candidates = try scope.allocator.dupe(config.AiModel, candidates);
        for (@constCast(self.candidates)) |*candidate| candidate.id = try controls.owned(scope, candidate.id);
        try scope.onCleanup(Editor, self, release);
        self.modal = try ui.widgets.Modal(.{ .open = ui.split(self.open, cx.on(Editor, self, opened)), .width = @as(f32, 480), .max_height = @as(f32, 640), .background = S.theme.current().overlay, .close_on_overlay = true }).mount(scope, cx);
        self.modal.overlay.meta.ownership.meta.test_id = "settings.ai.model.overlay";
        self.modal.dialog.meta.ownership.meta.test_id = "settings.ai.model.dialog";
        self.modal.dialog.setStyleInline(cx.allocator, .{ .width = .{ .px = 480 }, .height = .{ .px = 550 }, .padding = .{}, .direction = .column, .gap = 0, .background = S.theme.current().overlay, .glass = S.theme.overlayGlass(), .border = .{ .radius = 14 }, .overflow_hidden = true });
        self.modal.body.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .min_height = 0, .flex = 1, .direction = .column, .gap = 0, .padding = .{} });
        const header = try ui.box(cx, S.modelDialogHeader(), .{});
        header.setStyleInline(cx.allocator, .{ .gap = 8 });
        const title_icon = try ui.iconTint(cx, ui.icons.settings_2, S.theme.current().accent, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
        title_icon.meta.ownership.meta.test_id = "settings.ai.model.title.icon";
        title_icon.setStyleInline(cx.allocator, .{ .align_self = .start, .margin = .{ .top = 2 } });
        try header.appendChild(cx.allocator, title_icon);
        const title = try ui.box(cx, .{ .width = .fill(), .flex = 1, .min_width = 0, .direction = .column, .gap = 3 }, .{});
        try title.appendChild(cx.allocator, try ui.text(cx, if (index == null) "添加模型" else "编辑模型", .{ .font_size = 13, .font_weight = 650, .line_height = 20.0 / 13.0, .color = S.theme.current().fg_1 }));
        try title.appendChild(cx.allocator, try ui.text(cx, try controls.owned(scope, name), .{ .font_size = 11, .font_weight = 400, .line_height = 18.0 / 11.0, .color = S.theme.current().fg_2 }));
        try header.appendChild(cx.allocator, title);
        const close = try ui.widgets.Button(.{ .variant = .ghost, .hover_style = S.buttonHover(), .icon_asset = ui.icons.x, .icon_size = @as(f32, 16), .icon_only = true, .a11y_label = "关闭模型配置", .base_style = S.ButtonStyle{ .width = .{ .px = 30 }, .height = .{ .px = 30 }, .padding = .ZERO, .background = ui.Color.TRANSPARENT, .corner_radius = 7 }, .on_click = cx.on(Editor, self, cancel) }).mount(scope, cx);
        close.meta.ownership.meta.test_id = "settings.ai.model.close";
        try header.appendChild(cx.allocator, close);
        try self.modal.body.appendChild(cx.allocator, header);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 });
        scroll.container.meta.ownership.meta.test_id = "settings.ai.model.viewport";
        var content_style = S.modelDialogContent();
        content_style.gap = 15;
        scroll.content.setStyleInline(cx.allocator, content_style);
        const catalog_bar = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 25 }, .margin = .{ .bottom = -5 }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 }, .{});
        const catalog_note = try ui.textStyled(cx, S.note, "从清单选择，或手动输入模型 ID");
        catalog_note.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
        catalog_note.meta.ownership.meta.test_id = "settings.ai.model.catalog_status";
        self.catalog_status = catalog_note;
        try catalog_bar.appendChild(cx.allocator, catalog_note);
        const fetch = try ui.widgets.Button(.{ .variant = .ghost, .label = "获取模型清单", .base_style = S.ButtonStyle{ .width = .{ .px = 78 }, .height = .{ .px = 25 }, .padding = .{ .left = 6, .right = 6 }, .background = ui.Color.TRANSPARENT, .text_color = S.theme.current().accent_ink, .font_size = 11, .font_weight = 400 }, .on_click = cx.on(Editor, self, fetchModels) }).mount(scope, cx);
        fetch.meta.ownership.meta.test_id = "settings.ai.model.fetch_models";
        self.catalog_fetch = fetch;
        try catalog_bar.appendChild(cx.allocator, fetch);
        try scroll.content.appendChild(cx.allocator, catalog_bar);
        try self.modelChoice(scroll.content);
        self.inputs[1] = try self.field(scroll.content, "上下文窗口 *", self.context, "settings.ai.model.context");
        const capabilities = try ui.box(cx, S.modelCapabilities(), .{});
        const capability_heading = try ui.box(cx, S.modelCapabilityHeading(), .{});
        capability_heading.meta.ownership.meta.test_id = "settings.ai.model.capabilities.heading";
        try capability_heading.appendChild(cx.allocator, try ui.textStyled(cx, S.blockTitle, "模型能力"));
        try capabilities.appendChild(cx.allocator, capability_heading);
        try self.capability(capabilities, "推理能力", "settings.ai.model.reasoning", .reasoning, model.reasoning);
        self.effort_body = try ui.box(cx, S.modelEffortBody(), .{});
        const effort_heading = try ui.box(cx, .{ .width = .fill(), .direction = .row, .align_items = .center }, .{});
        try effort_heading.appendChild(cx.allocator, try ui.textStyled(cx, S.note, "推理等级"));
        try effort_heading.appendChild(cx.allocator, try ui.spacer(cx));
        try effort_heading.appendChild(cx.allocator, try ui.textStyled(cx, S.note, "可多选"));
        try self.effort_body.appendChild(cx.allocator, effort_heading);
        const efforts = try ui.grid(cx, .{ .columns = &.{ .{ .fr = 1 }, .{ .fr = 1 }, .{ .fr = 1 }, .{ .fr = 1 } }, .rows = &.{ .{ .px = 30 }, .{ .px = 30 } }, .column_gap = 6, .row_gap = 6, .height = .{ .px = 66 } }, .{});
        efforts.setStyleInline(cx.allocator, .{ .width = .fill(), .flex_shrink = 0 });
        efforts.meta.ownership.meta.test_id = "settings.ai.model.efforts";
        // Display in strength order while preserving the stored effort indices.
        const labels = [_][]const u8{ "low", "medium", "high", "xhigh", "max", "none", "ultra" };
        for ([_]usize{ 5, 0, 1, 2, 3, 4, 6 }) |i| {
            self.efforts[i] = try scope.createSignal(bool, model.efforts[i]);
            const check = try ui.widgets.Checkbox(.{ .checked = self.efforts[i], .label = labels[i], .box_size = @as(f32, 12), .label_font_size = @as(f32, 11) }).mount(scope, cx);
            check.setStyleInline(cx.allocator, S.modelEffortOption());
            self.checks[i] = check;
            check.meta.ownership.meta.test_id = ([_][]const u8{ "settings.ai.model.effort.low", "settings.ai.model.effort.medium", "settings.ai.model.effort.high", "settings.ai.model.effort.xhigh", "settings.ai.model.effort.max", "settings.ai.model.effort.none", "settings.ai.model.effort.ultra" })[i];
            try efforts.appendChild(cx.allocator, check);
        }
        try self.effort_body.appendChild(cx.allocator, efforts);
        self.effort_body.setDisplay(if (model.reasoning) .flex else .none);
        try capabilities.appendChild(cx.allocator, self.effort_body);
        try self.capability(capabilities, "识图能力", "settings.ai.model.vision", .vision, model.vision);
        try scroll.content.appendChild(cx.allocator, capabilities);
        const test_row = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = 52, .margin = .{ .top = -3 }, .direction = .row, .align_items = .center, .gap = 12, .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 }, .background = S.theme.current().well, .border = .{ .radius = 8 }, .flex_shrink = 0 }, .{});
        const test_status = try ui.textStyled(cx, S.label, "未测试");
        test_status.meta.ownership.meta.test_id = "settings.ai.model.test_status";
        test_status.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
        if (test_status.getText()) |old| {
            var properties = old;
            properties.wrap = .word;
            properties.text_overflow = .clip;
            test_status.setText(properties);
        }
        self.test_status = test_status;
        try test_row.appendChild(cx.allocator, test_status);
        var test_style = S.modelDialogButton(false);
        test_style.width = .{ .px = 72 };
        const test_button = try ui.widgets.Button(.{ .label = "测试模型", .variant = .secondary, .base_style = test_style, .on_click = cx.on(Editor, self, testModel) }).mount(scope, cx);
        test_button.meta.ownership.meta.test_id = "settings.ai.model.test";
        self.test_button = test_button;
        try test_row.appendChild(cx.allocator, test_button);
        try scroll.content.appendChild(cx.allocator, test_row);
        const default_value = try scope.createSignal(bool, model.default);
        const default_check = try ui.widgets.Checkbox(.{ .checked = default_value, .on_change = cx.on(Editor, self, setDefault), .label = "设为此服务提供方的默认模型", .box_size = @as(f32, 13), .label_font_size = @as(f32, 12) }).mount(scope, cx);
        default_check.setStyleInline(cx.allocator, .{ .height = .{ .px = 30 }, .margin = .{ .top = 1 }, .flex_shrink = 0 });
        self.checks[7] = default_check;
        default_check.meta.ownership.meta.test_id = "settings.ai.model.default";
        try scroll.content.appendChild(cx.allocator, default_check);
        const error_node = try ui.text(cx, "", S.errorNote(cx.tokens));
        error_node.meta.ownership.meta.test_id = "settings.ai.model.error";
        error_node.setStyleInline(cx.allocator, .{ .width = .fill(), .min_height = 16 });
        try ui.bindText(cx, scope, self.error_text, error_node);
        try scroll.content.appendChild(cx.allocator, error_node);
        try self.modal.body.appendChild(cx.allocator, scroll.container);
        const footer = try ui.box(cx, S.modelDialogFooter(), .{});
        footer.meta.ownership.meta.test_id = "settings.ai.model.footer";
        try footer.appendChild(cx.allocator, try ui.spacer(cx));
        var cancel_style = S.modelDialogButton(false);
        cancel_style.width = .{ .px = 48 };
        const cancel_button = try ui.widgets.Button(.{ .variant = .secondary, .hover_style = S.buttonHover(), .label = "取消", .base_style = cancel_style, .on_click = cx.on(Editor, self, cancel) }).mount(scope, cx);
        cancel_button.meta.ownership.meta.test_id = "settings.ai.model.cancel";
        try footer.appendChild(cx.allocator, cancel_button);
        var save_style = S.modelDialogButton(true);
        save_style.width = .{ .px = 72 };
        const save = try ui.widgets.Button(.{ .label = if (index == null) "添加模型" else "保存模型", .variant = .primary, .base_style = save_style, .on_click = cx.on(Editor, self, commit) }).mount(scope, cx);
        self.save_button = save;
        save.meta.ownership.meta.test_id = "settings.ai.model.save";
        try footer.appendChild(cx.allocator, save);
        try self.modal.body.appendChild(cx.allocator, footer);
        self.resize();
        return self;
    }
    fn release(self: *Editor) void {
        self.catalog_rows.deinit(self.scope.allocator);
        self.scope.allocator.free(self.candidates);
        self.scope.allocator.destroy(self);
    }
    pub fn destroy(self: *Editor) void {
        const cx = self.cx;
        const scope = self.scope;
        const overlay = self.modal.overlay;
        cx.invalidateReferencesTo(overlay);
        if (overlay.parent) |parent| cx.detachChild(parent, overlay);
        scope.dispose();
        cx.destroyDetached(overlay);
    }
    pub fn resize(self: *Editor) void {
        if (self.save_button) |button| {
            const colors = S.theme.current();
            button.setStyleInline(self.cx.allocator, .{ .background = colors.action_accent, .gradient = .{ .from = colors.action_accent, .to = colors.action_accent_2, .direction = .diagonal }, .text_color = S.theme.actionForeground(colors.action_accent) });
            paintTextColor(button, S.theme.actionForeground(colors.action_accent));
        }
        if (self.test_signature) |signature| if (signature != self.testSignature()) {
            if (self.test_status) |node| node.setTextContent(self.cx.allocator, "未测试") catch {};
        };
        for (self.checks) |node| if (node) |check| S.paintControlText(check);
        self.paintCatalogRows();
        const inset = @import("../ui/v3_geometry.zig").settings_inset;
        const settings_width = @min(S.geometry.panel_width, @max(1, self.cx.viewport.width - 2 * inset));
        const settings_height = @import("settings_content_view.zig").constrainedModalHeight(0, self.cx.viewport.height);
        const width = @min(480, @max(1, settings_width - 16));
        const height = @min(550, @max(1, settings_height - 16));
        if (self.modal.dialog.style.width == .px and self.modal.dialog.style.width.px == width and self.modal.dialog.style.height == .px and self.modal.dialog.style.height.px == height) return;
        self.modal.dialog.setStyleInline(self.cx.allocator, .{ .width = .{ .px = width }, .height = .{ .px = height } });
    }
    pub fn isComposing(self: *const Editor) bool {
        for (self.inputs) |input| if (input.state.imeIsComposing()) return true;
        return false;
    }
    pub fn consumeEscape(self: *Editor) bool {
        if (self.isComposing()) return false;
        for (self.select_open) |open| if (open) |value| if (value.peek()) {
            value.set(false);
            return true;
        };
        self.cancel();
        return true;
    }
    pub fn cancel(self: *Editor) void {
        if (self.isComposing()) return;
        self.done = true;
        self.open.set(false);
        self.cx.requestRedraw();
    }
    fn opened(self: *Editor, value: bool) void {
        if (!value) self.cancel();
    }
    fn chooseCandidate(self: *Editor, selected: ?[]const u8) void {
        const id = selected orelse return;
        if (id.len == 0) {
            self.cx.setFocus(self.inputs[0].input_container);
            return;
        }
        for (self.candidates) |candidate| if (std.mem.eql(u8, candidate.id, id)) {
            const was_default = self.model.default;
            self.model = candidate;
            self.model.default = was_default;
            const metadata = self.hooks.metadata(self.hooks.context, candidate.id);
            self.capability_known = if (metadata) |m| .{ m.reasoning_known, m.vision_known } else @splat(false);
            self.refreshCapabilitySources(true);
            self.id.set(candidate.id);
            if (self.catalog_label) |label| label.setTextContent(self.cx.allocator, candidate.id) catch {};
            if (self.catalog_query) |query| query.set(candidate.id);
            if (self.select_open[2]) |open| open.set(false);
            var buffer: [32]u8 = undefined;
            const context = std.fmt.bufPrint(&buffer, "{d}", .{candidate.context_window}) catch return;
            self.context.set(if (candidate.context_window == 0) "" else controls.owned(self.scope, context) catch return);
            if (self.context_source) |source| source.set(if (candidate.context_window == 0) .missing else .api);
            for (self.efforts, candidate.efforts) |value, enabled| value.set(enabled);
            self.effort_body.setDisplay(if (candidate.reasoning) .flex else .none);
            if (self.capability_values[0]) |value| value.set(if (!self.capability_known[0]) "unknown" else if (candidate.reasoning) "yes" else "no");
            if (self.capability_values[1]) |value| value.set(if (!self.capability_known[1]) "unknown" else if (candidate.vision) "yes" else "no");
            self.error_text.set("");
            self.cx.requestRedraw();
            return;
        };
    }
    const CandidateChoice = struct {
        editor: *Editor,
        id: []const u8,
        fn choose(self: *@This()) void {
            self.editor.chooseCandidate(self.id);
        }
    };
    fn modelChoice(self: *Editor, parent: *ui.Node) !void {
        const cx = self.cx;
        const group = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .flex_shrink = 0 }, .{});
        try group.appendChild(cx.allocator, try ui.textStyled(cx, S.label, "模型 ID *"));
        const popup = try ui.widgets.Popover(.{ .width = @as(f32, 440), .max_width = @as(f32, 440), .max_height = @as(f32, 280), .match_trigger_width = true, .constrain_width_to_viewport = true, .size_policy = .fit_or_scroll, .close_on_escape = true, .on_open_change = cx.on(Editor, self, catalogOpened) }).mount(self.scope, cx);
        popup.chrome.meta.ownership.meta.test_id = "settings.ai.model.catalog_popup";
        self.catalog_popup = popup;
        self.select_open[2] = popup.open;
        popup.wrapper.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} } });
        var trigger_style = S.providerInput(0, 32);
        trigger_style.direction = .row;
        trigger_style.align_items = .center;
        trigger_style.gap = 8;
        popup.trigger.setStyleInline(cx.allocator, trigger_style);
        popup.trigger.meta.ownership.meta.test_id = "settings.ai.model.catalog";
        const label = try ui.text(cx, if (self.id.peek().len == 0) "请选择" else self.id.peek(), .{ .font_size = 12, .font_weight = 400, .color = S.theme.current().fg_1, .text_overflow = .ellipsis });
        label.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0, .height = .{ .px = 18 } });
        self.catalog_label = label;
        try popup.trigger.appendChild(cx.allocator, label);
        try popup.trigger.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.chevron_down, S.theme.current().fg_2, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 }));
        popup.chrome.setStyleInline(cx.allocator, .{ .padding = ui.Padding.all(6), .background = S.theme.current().overlay, .border = .{ .radius = 8 } });
        popup.content.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 4 });
        self.catalog_query = try popup.scope.createText("", .{});
        var search = try ui.widgets.Input(.{ .value = self.catalog_query.?, .placeholder = "搜索模型或输入模型 ID", .on_change = cx.on(Editor, self, filterCandidates), .on_submit = cx.on(Editor, self, commitQuery) }).mountResult(popup.scope, cx);
        @import("../ui/app_theme.zig").styleInput(search);
        search.input_container.setStyleInline(cx.allocator, S.providerInput(0, 32));
        search.input_container.meta.ownership.meta.test_id = "settings.ai.model.id";
        search.node.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 32 }, .flex_shrink = 0 });
        S.tuneInput(&search);
        search.node.behavior.events.capture_context = self;
        search.node.behavior.events.on_event_capture = catalogKey;
        self.inputs[0] = search;
        try popup.content.appendChild(cx.allocator, search.node);
        const list = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(popup.scope, cx);
        list.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 220 }, .flex_shrink = 0 });
        list.content.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 2 });
        self.catalog_scroll = list;
        self.catalog_options = list.content;
        try popup.content.appendChild(cx.allocator, list.container);
        try self.mountCandidateRows();
        const custom = try ui.widgets.Button(.{ .label = "使用输入的模型 ID", .variant = .ghost, .hover_style = S.buttonHover(), .base_style = S.ButtonStyle{ .width = .fill(), .height = .{ .px = 30 }, .padding = .{ .left = 10, .right = 10 }, .justify = .start, .font_size = 12, .font_weight = 400, .flex_shrink = 0 }, .on_click = cx.on(Editor, self, chooseCustom) }).mount(popup.scope, cx);
        custom.meta.ownership.meta.test_id = "settings.ai.model.catalog.manual";
        custom.setDisplay(.none);
        self.catalog_custom = custom;
        try popup.content.appendChild(cx.allocator, custom);
        try group.appendChild(cx.allocator, popup.wrapper);
        try parent.appendChild(cx.allocator, group);
        self.filterCandidates("");
    }
    fn catalogOpened(self: *Editor, open: bool) void {
        if (!open) return;
        if (self.catalog_query) |query| query.set("");
        self.filterCandidates("");
        for (self.candidates, 0..) |candidate, i| if (std.mem.eql(u8, candidate.id, self.id.peek())) {
            self.catalog_active = i;
            break;
        };
        if (self.catalog_scroll) |list| ui.widgets.setScrollY(list.state, list.content, 0);
        self.paintCatalogRows();
        self.cx.setFocus(self.inputs[0].input_container);
    }
    fn catalogKey(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Editor = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event != .key_down or self.inputs[0].state.imeIsComposing()) return .ignored;
        const key = event.key_down.key;
        if (key != .up and key != .down) return .ignored;
        if (event.key_down.modifiers.super or event.key_down.modifiers.ctrl or event.key_down.modifiers.alt) return .ignored;
        const count = self.catalog_rows.items.len;
        if (count == 0) return .stop;
        var index = self.catalog_active orelse if (key == .down) count - 1 else 0;
        for (0..count) |_| {
            index = if (key == .down) (index + 1) % count else (index + count - 1) % count;
            if (self.catalog_rows.items[index].style.display != .none) {
                self.catalog_active = index;
                self.paintCatalogRows();
                self.scrollCatalogActive();
                self.cx.requestRedraw();
                break;
            }
        }
        return .stop;
    }
    fn paintCatalogRows(self: *Editor) void {
        const colors = S.theme.current();
        for (self.catalog_rows.items, self.candidates, 0..) |row, candidate, i| {
            row.setStyleInline(self.cx.allocator, .{ .justify = .start, .font_size = 12, .font_weight = 400, .background = if (self.catalog_active == i) S.theme.popupSelection() else ui.Color.TRANSPARENT });
            paintTextColor(row, if (std.mem.eql(u8, candidate.id, self.id.peek())) colors.accent_ink else colors.fg_1);
        }
    }
    fn scrollCatalogActive(self: *Editor) void {
        const index = self.catalog_active orelse return;
        const list = self.catalog_scroll orelse return;
        ui.widgets.scrollIntoView(list.state, list.content, self.catalog_rows.items[index], .nearest);
    }
    fn commitQuery(self: *Editor, _: []const u8) void {
        if (self.inputs[0].state.imeIsComposing()) return;
        if (self.catalog_active) |index| {
            if (index < self.candidates.len and self.catalog_rows.items[index].style.display != .none) {
                self.chooseCandidate(self.candidates[index].id);
                return;
            }
        }
        self.chooseCustom();
    }
    fn fetchModels(self: *Editor) void {
        self.hooks.fetch_models(self.hooks.context, self.provider);
    }
    fn mountCandidateRows(self: *Editor) !void {
        const cx = self.cx;
        const popup = self.catalog_popup.?;
        for (self.candidates, 0..) |candidate, i| {
            const state = try popup.scope.createState(CandidateChoice, .{ .editor = self, .id = candidate.id });
            const row = try ui.widgets.Button(.{ .label = candidate.id, .variant = .ghost, .hover_style = S.buttonHover(), .base_style = S.ButtonStyle{ .width = .fill(), .height = .{ .px = 30 }, .padding = .{ .left = 10, .right = 10 }, .justify = .start, .font_size = 12, .font_weight = 400, .border = .{ .radius = 6 }, .flex_shrink = 0 }, .on_click = cx.on(CandidateChoice, state, CandidateChoice.choose) }).mount(popup.scope, cx);
            var buffer: [80]u8 = undefined;
            row.meta.ownership.meta.test_id = try controls.owned(popup.scope, try std.fmt.bufPrint(&buffer, "settings.ai.model.catalog.option.{d}", .{i}));
            try self.catalog_rows.append(self.scope.allocator, row);
            try self.catalog_options.?.appendChild(cx.allocator, row);
        }
    }
    pub fn updateCatalog(self: *Editor, candidates: []const config.AiModel, message: []const u8, busy: bool) !void {
        if (self.catalog_status) |node| {
            try node.setTextContent(self.cx.allocator, if (message.len != 0) message else "从清单选择，或手动输入模型 ID");
        }
        if (self.catalog_fetch) |button| setButtonText(self.cx, button, if (busy) "取消获取" else "获取模型清单");
        if (busy) return;
        const options = self.catalog_options orelse return;
        while (options.children.items.len != 0) {
            const child = options.children.items[options.children.items.len - 1];
            self.cx.invalidateReferencesTo(child);
            self.cx.detachChild(options, child);
            self.cx.destroyDetached(child);
        }
        self.catalog_rows.clearRetainingCapacity();
        self.scope.allocator.free(self.candidates);
        self.candidates = try self.scope.allocator.dupe(config.AiModel, candidates);
        for (@constCast(self.candidates)) |*candidate| candidate.id = try controls.owned(self.scope, candidate.id);
        try self.mountCandidateRows();
        self.filterCandidates(self.catalog_query.?.peek());
    }
    fn paintTextColor(node: *ui.Node, color: ui.Color) void {
        if (node.getText() != null) node.setTextColor(color);
        for (node.children.items) |child| paintTextColor(child, color);
    }
    fn setButtonText(cx: *ui.Cx, node: *ui.Node, value: []const u8) void {
        if (node.getText() != null) {
            node.setTextContent(cx.allocator, value) catch {};
            return;
        }
        for (node.children.items) |child| setButtonText(cx, child, value);
    }
    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        for (0..haystack.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
        return false;
    }
    fn filterCandidates(self: *Editor, input: []const u8) void {
        const query = std.mem.trim(u8, input, " \t\r\n");
        var exact = false;
        var visible: usize = 0;
        self.catalog_active = null;
        for (self.candidates, self.catalog_rows.items, 0..) |candidate, row, index| {
            const matches = containsIgnoreCase(candidate.id, query);
            row.setDisplay(if (matches) .flex else .none);
            if (matches) {
                if (self.catalog_active == null) self.catalog_active = index;
                visible += 1;
            }
            exact = exact or std.ascii.eqlIgnoreCase(candidate.id, query);
        }
        if (self.catalog_custom) |custom| custom.setDisplay(if (query.len != 0 and !exact) .flex else .none);
        const custom_visible = query.len != 0 and !exact;
        if (self.catalog_scroll) |list| {
            list.container.setStyleInline(self.cx.allocator, .{ .height = .{ .px = @min(if (custom_visible) @as(f32, 184) else 220, @as(f32, @floatFromInt(visible)) * 32) } });
            ui.widgets.setScrollY(list.state, list.content, 0);
        }
        if (self.catalog_popup) |popup| {
            var ancestor = popup.content.parent;
            while (ancestor) |node| : (ancestor = node.parent) {
                if (node.tag == .scroll) {
                    node.setStyleInline(self.cx.allocator, .{ .height = .{ .px = @min(268, 36 + @as(f32, @floatFromInt(visible + @intFromBool(custom_visible))) * 32) }, .width = .fill() });
                    break;
                }
                if (node == popup.chrome) break;
            }
        }
        self.paintCatalogRows();
        self.cx.requestRedraw();
    }
    fn chooseCustom(self: *Editor) void {
        const query = self.catalog_query orelse return;
        const id = std.mem.trim(u8, query.peek(), " \t");
        if (id.len == 0) return;
        const owned = controls.owned(self.scope, id) catch return;
        self.id.set(owned);
        self.model = .{ .id = owned, .default = self.model.default, .context_window = 0, .efforts = @splat(false) };
        for (self.efforts) |effort| effort.set(false);
        self.effort_body.setDisplay(.none);
        self.context.set("");
        if (self.context_source) |source| source.set(.missing);
        self.capability_known = @splat(false);
        self.refreshCapabilitySources(false);
        for (self.capability_values) |value| if (value) |v| v.set("unknown");
        if (self.catalog_label) |label| label.setTextContent(self.cx.allocator, owned) catch {};
        if (self.select_open[2]) |open| open.set(false);
        self.error_text.set("");
    }
    fn testModel(self: *Editor) void {
        if (self.id.peek().len == 0) {
            self.error_text.set("先选择或输入模型 ID，再测试。");
            return;
        }
        var model = self.model;
        model.id = self.id.peek();
        model.context_window = std.fmt.parseInt(u32, self.context.peek(), 10) catch 8192;
        self.hooks.test_model(self.hooks.context, self.provider, model);
    }
    fn testSignature(self: *Editor) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(self.id.peek());
        hash.update(self.context.peek());
        std.hash.autoHash(&hash, self.model.reasoning);
        std.hash.autoHash(&hash, self.model.vision);
        for (self.efforts) |effort| std.hash.autoHash(&hash, effort.peek());
        return hash.final();
    }
    pub fn updateTest(self: *Editor, message: []const u8, busy: bool) void {
        if (busy) self.test_signature = self.testSignature();
        const current = self.test_signature == self.testSignature();
        if (self.test_status) |node| node.setTextContent(self.cx.allocator, if (current) message else "未测试") catch {};
        if (self.test_button) |node| setButtonText(self.cx, node, if (busy) "取消测试" else "测试模型");
    }
    fn setDefault(self: *Editor, value: bool) void {
        self.model.default = value;
    }
    fn commit(self: *Editor) void {
        if (self.isComposing()) return;
        if (!self.capability_known[0] or !self.capability_known[1]) {
            self.error_text.set(if (!self.capability_known[0]) "接口未返回推理能力，请手动选择。" else "接口未返回识图能力，请手动选择。");
            return;
        }
        var model = self.model;
        model.id = self.id.peek();
        model.context_window = std.fmt.parseInt(u32, std.mem.trim(u8, self.context.peek(), " \t"), 10) catch {
            self.error_text.set(draft.problemText(error.InvalidContextWindow));
            return;
        };
        for (self.efforts, 0..) |value, i| model.efforts[i] = value.peek();
        self.hooks.commit(self.hooks.context, self.provider, self.index, model) catch |err| {
            self.error_text.set(draft.problemText(err));
            return;
        };
        self.done = true;
        self.open.set(false);
        self.cx.requestRedraw();
    }
    fn contextEdited(self: *Editor, _: []const u8) void {
        if (self.context_source) |source| source.set(.manual);
    }
    fn field(self: *Editor, parent: *ui.Node, label: []const u8, value: *ui.Signal([]const u8), id: []const u8) !ui.widgets.input.InputResult {
        const group = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .flex_shrink = 0 }, .{});
        const heading = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 18 }, .direction = .row, .gap = 6, .align_items = .center }, .{});
        try heading.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.label, label));
        const source = try SourceIndicator.mount(self, heading, if (self.index != null) .manual else .missing, "settings.ai.model.context.source");
        self.context_source = source;
        try group.appendChild(self.cx.allocator, heading);
        var input = try ui.widgets.Input(.{ .value = value, .placeholder = "例如 128000", .append_text = "tokens", .on_change = self.cx.on(Editor, self, contextEdited) }).mountResult(self.scope, self.cx);
        @import("../ui/app_theme.zig").styleInput(input);
        input.input_container.setStyleInline(self.cx.allocator, S.providerInput(0, 32));
        input.input_container.meta.ownership.meta.test_id = id;
        input.node.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 32 }, .flex_shrink = 0 });
        S.tuneInput(&input);
        try group.appendChild(self.cx.allocator, input.node);
        try parent.appendChild(self.cx.allocator, group);
        return input;
    }
    fn refreshCapabilitySources(self: *Editor, from_api: bool) void {
        for (self.capability_sources, self.capability_known) |source, known| if (source) |node| node.set(if (!known) .missing else if (from_api) .api else .manual);
    }
    const Capability = struct {
        editor: *Editor,
        kind: enum { reasoning, vision },
        fn changed(self: *@This(), value: ?[]const u8) void {
            const selected = value orelse return;
            if (std.mem.eql(u8, selected, "unknown")) return;
            const capability_index: usize = if (self.kind == .reasoning) 0 else 1;
            self.editor.capability_known[capability_index] = true;
            if (self.editor.capability_sources[capability_index]) |source| source.set(.manual);
            const enabled = std.mem.eql(u8, selected, "yes");
            switch (self.kind) {
                .reasoning => {
                    self.editor.model.reasoning = enabled;
                    self.editor.effort_body.setDisplay(if (enabled) .flex else .none);
                },
                .vision => self.editor.model.vision = enabled,
            }
        }
    };
    fn capability(self: *Editor, parent: *ui.Node, label: []const u8, id: []const u8, kind: @FieldType(Capability, "kind"), enabled: bool) !void {
        const row = try ui.box(self.cx, S.modelCapabilityRow(), .{});
        const identity = try ui.box(self.cx, .{ .height = .{ .fit = .{} }, .direction = .row, .gap = 6, .align_items = .center }, .{});
        try identity.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.label, label));
        const capability_index: usize = if (kind == .reasoning) 0 else 1;
        const source = try SourceIndicator.mount(self, identity, if (self.capability_known[capability_index]) .manual else .missing, try controls.stableId(self.scope, id, ".source"));
        self.capability_sources[capability_index] = source;
        try row.appendChild(self.cx.allocator, identity);
        try row.appendChild(self.cx.allocator, try ui.spacer(self.cx));
        const state = try self.scope.createState(Capability, .{ .editor = self, .kind = kind });
        const value = try self.scope.createSignal(?[]const u8, if (!self.capability_known[capability_index]) "unknown" else if (enabled) "yes" else "no");
        self.capability_values[if (kind == .reasoning) 0 else 1] = value;
        const select = try ui.widgets.Select(.{ .value = value, .on_change = self.cx.on(Capability, state, Capability.changed), .width = @as(f32, 170), .options = &[_]ui.widgets.SelectOption{ .{ .value = "unknown", .label = "未返回，请选择", .disabled = true }, .{ .value = "yes", .label = "支持", .test_id = if (kind == .reasoning) "settings.ai.model.reasoning.yes" else "settings.ai.model.vision.yes" }, .{ .value = "no", .label = "不支持", .test_id = if (kind == .reasoning) "settings.ai.model.reasoning.no" else "settings.ai.model.vision.no" } } }).mount(self.scope, self.cx);
        self.select_open[if (kind == .reasoning) 0 else 1] = select.open;
        select.trigger.setStyleInline(self.cx.allocator, S.providerInput(170, 32));
        select.content_slot.setStyleInline(self.cx.allocator, .{ .font_size = 12, .font_weight = 400 });
        select.trigger.meta.ownership.meta.test_id = id;
        try row.appendChild(self.cx.allocator, select.wrapper);
        try parent.appendChild(self.cx.allocator, row);
    }
};

/// Compact metadata provenance; icon shape and a tooltip supplement its color.
const SourceIndicator = struct {
    const Kind = enum { api, manual, missing };
    icons: [3]*ui.Node,
    text: *ui.Signal([]const u8),
    open: *ui.Signal(bool),
    trigger: *ui.Node,
    fn mount(editor: *Editor, parent: *ui.Node, kind: Kind, id: []const u8) !*SourceIndicator {
        const cx = editor.cx;
        const scope = editor.scope;
        const self = try scope.createState(SourceIndicator, .{ .icons = undefined, .text = try scope.createText("", .{}), .open = try scope.createSignal(bool, false), .trigger = undefined });
        const tip = try ui.widgets.Tooltip(.{ .text = self.text, .open = self.open, .open_delay_ms = 450, .background = S.theme.current().overlay, .text_color = S.theme.current().fg_1, .font_size = 11 }).mount(scope, cx);
        tip.content.meta.ownership.meta.test_id = try controls.stableId(scope, id, ".tooltip");
        self.trigger = tip.trigger;
        tip.trigger.meta.ownership.meta.test_id = id;
        tip.trigger.setStyleInline(cx.allocator, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .align_items = .center, .justify = .center, .flex_shrink = 0 });
        tip.trigger.setFocusable(true);
        tip.trigger.behavior.events.on_focus = .{ .callback = focus, .context = self };
        tip.trigger.behavior.events.on_blur = .{ .callback = blur, .context = self };
        const assets = [_]ui.SvgAsset{ ui.icons.circle_check, ui.icons.pencil, ui.icons.circle_alert };
        const colors = S.theme.current();
        for (assets, [_]ui.Color{ colors.ok, colors.fg_2, colors.warn_ink }, 0..) |asset, color, i| {
            self.icons[i] = try ui.iconTint(cx, asset, color, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 });
            try tip.trigger.appendChild(cx.allocator, self.icons[i]);
        }
        self.set(kind);
        try parent.appendChild(cx.allocator, tip.wrapper);
        return self;
    }
    fn set(self: *SourceIndicator, kind: Kind) void {
        const label: []const u8 = switch (kind) {
            .api => "接口已返回",
            .manual => "手动设置",
            .missing => "接口未返回，请补充",
        };
        self.text.set(label);
        self.trigger.behavior.interaction.a11y = .{ .label = label };
        for (self.icons, 0..) |icon, i| icon.setDisplay(if (i == @backingInt(kind)) .flex else .none);
    }
    fn focus(raw: *anyopaque) void {
        const self: *SourceIndicator = @ptrCast(@alignCast(raw));
        self.open.set(true);
    }
    fn blur(raw: *anyopaque) void {
        const self: *SourceIndicator = @ptrCast(@alignCast(raw));
        self.open.set(false);
    }
};
