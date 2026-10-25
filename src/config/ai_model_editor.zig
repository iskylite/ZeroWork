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
    efforts: [5]*ui.Signal(bool) = undefined,
    effort_body: *ui.Node = undefined,
    select_open: [2]?*ui.Signal(bool) = @splat(null),
    checks: [6]?*ui.Node = @splat(null),

    pub fn mount(cx: *ui.Cx, parent: *ui.Scope, provider: usize, index: ?usize, name: []const u8, model: config.AiModel, hooks: Hooks) !*Editor {
        const scope = try parent.childScope();
        errdefer scope.dispose();
        const self = try scope.allocator.create(Editor);
        var buffer: [32]u8 = undefined;
        self.* = .{ .scope = scope, .cx = cx, .hooks = hooks, .provider = provider, .index = index, .model = model, .open = try scope.createSignal(bool, true), .id = try scope.createText(model.id, .{}), .context = try scope.createText(if (model.context_window == 0) "" else try std.fmt.bufPrint(&buffer, "{d}", .{model.context_window}), .{}), .error_text = try scope.createText("", .{}), .modal = undefined };
        try scope.onCleanup(Editor, self, release);
        self.modal = try ui.widgets.Modal(.{ .open = ui.split(self.open, cx.on(Editor, self, opened)), .width = @as(f32, 480), .max_height = @as(f32, 640), .background = S.theme.current().overlay, .close_on_overlay = true }).mount(scope, cx);
        self.modal.overlay.meta.ownership.meta.test_id = "settings.ai.model.overlay";
        self.modal.dialog.meta.ownership.meta.test_id = "settings.ai.model.dialog";
        self.modal.dialog.setStyleInline(cx.allocator, .{ .width = .{ .px = 480 }, .height = .{ .px = 550 }, .padding = .{}, .direction = .column, .gap = 0, .background = S.theme.current().overlay, .border = .{ .radius = 14 }, .overflow_hidden = true });
        self.modal.body.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .min_height = 0, .flex = 1, .direction = .column, .gap = 0, .padding = .{} });
        const header = try ui.box(cx, S.modelDialogHeader(), .{});
        const title = try ui.box(cx, .{ .width = .fill(), .flex = 1, .min_width = 0, .direction = .column, .gap = 3 }, .{});
        try title.appendChild(cx.allocator, try ui.textStyled(cx, S.title, if (index == null) "添加模型" else "编辑模型"));
        try title.appendChild(cx.allocator, try ui.textStyled(cx, S.note, try controls.owned(scope, name)));
        try header.appendChild(cx.allocator, title);
        const close = try ui.widgets.Button(.{ .variant = .ghost, .hover_style = S.buttonHover(), .icon_asset = ui.icons.x, .icon_only = true, .a11y_label = "关闭模型配置", .base_style = S.button(24, false), .on_click = cx.on(Editor, self, cancel) }).mount(scope, cx);
        close.meta.ownership.meta.test_id = "settings.ai.model.close";
        try header.appendChild(cx.allocator, close);
        try self.modal.body.appendChild(cx.allocator, header);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 });
        scroll.container.meta.ownership.meta.test_id = "settings.ai.model.viewport";
        scroll.content.setStyleInline(cx.allocator, S.modelDialogContent());
        self.inputs[0] = try self.field(scroll.content, "模型 ID", self.id, "settings.ai.model.id");
        self.inputs[1] = try self.field(scroll.content, "上下文窗口 · tokens", self.context, "settings.ai.model.context");
        const capabilities = try ui.box(cx, S.modelCapabilities(), .{});
        try capabilities.appendChild(cx.allocator, try ui.textStyled(cx, S.title, "模型能力"));
        try self.capability(capabilities, "推理能力", "settings.ai.model.reasoning", .reasoning, model.reasoning);
        self.effort_body = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 8, .padding = .{ .left = 10, .right = 10, .bottom = 12, .top = 4 }, .background = S.theme.current().well, .border = .{ .radius = 7 }, .flex_shrink = 0 }, .{});
        try self.effort_body.appendChild(cx.allocator, try ui.textStyled(cx, S.note, "支持的推理档位 · 可多选"));
        const efforts = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .flex_wrap = .wrap, .gap = 5, .flex_shrink = 0 }, .{});
        for ([_][]const u8{ "low", "medium", "high", "xhigh", "max" }, 0..) |label, i| {
            self.efforts[i] = try scope.createSignal(bool, model.efforts[i]);
            const check = try ui.widgets.Checkbox(.{ .checked = self.efforts[i], .label = label, .box_size = @as(f32, 12), .label_font_size = @as(f32, 11) }).mount(scope, cx);
            self.checks[i] = check;
            check.meta.ownership.meta.test_id = ([_][]const u8{ "settings.ai.model.effort.low", "settings.ai.model.effort.medium", "settings.ai.model.effort.high", "settings.ai.model.effort.xhigh", "settings.ai.model.effort.max" })[i];
            const option = try ui.box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} }, .padding = .{ .left = 8, .right = 8, .top = 7, .bottom = 7 }, .background = S.theme.current().surface_2, .border = .{ .radius = 6 }, .flex_shrink = 0 }, .{});
            try option.appendChild(cx.allocator, check);
            try efforts.appendChild(cx.allocator, option);
        }
        try self.effort_body.appendChild(cx.allocator, efforts);
        self.effort_body.setDisplay(if (model.reasoning) .flex else .none);
        try capabilities.appendChild(cx.allocator, self.effort_body);
        try self.capability(capabilities, "识图能力", "settings.ai.model.vision", .vision, model.vision);
        try scroll.content.appendChild(cx.allocator, capabilities);
        const default_value = try scope.createSignal(bool, model.default);
        const default_check = try ui.widgets.Checkbox(.{ .checked = ui.split(default_value, cx.on(Editor, self, setDefault)), .label = "设为此服务提供方的默认模型", .label_font_size = @as(f32, 11) }).mount(scope, cx);
        self.checks[5] = default_check;
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
        const cancel_button = try ui.widgets.Button(.{ .variant = .secondary, .hover_style = S.buttonHover(), .label = "取消", .base_style = S.modelDialogButton(false), .on_click = cx.on(Editor, self, cancel) }).mount(scope, cx);
        cancel_button.meta.ownership.meta.test_id = "settings.ai.model.cancel";
        try footer.appendChild(cx.allocator, cancel_button);
        const save = try ui.widgets.Button(.{ .label = if (index == null) "添加模型" else "保存模型", .variant = .primary, .base_style = S.modelDialogButton(true), .on_click = cx.on(Editor, self, commit) }).mount(scope, cx);
        save.meta.ownership.meta.test_id = "settings.ai.model.save";
        try footer.appendChild(cx.allocator, save);
        try self.modal.body.appendChild(cx.allocator, footer);
        self.resize();
        return self;
    }
    fn release(self: *Editor) void {
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
        for (self.checks) |node| if (node) |check| S.paintControlText(check);
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
    fn setDefault(self: *Editor, value: bool) void {
        self.model.default = value;
    }
    fn commit(self: *Editor) void {
        if (self.isComposing()) return;
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
    fn field(self: *Editor, parent: *ui.Node, label: []const u8, value: *ui.Signal([]const u8), id: []const u8) !ui.widgets.input.InputResult {
        const group = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .flex_shrink = 0 }, .{});
        try group.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.label, label));
        var input = try ui.widgets.Input(.{ .value = value, .placeholder = label }).mountResult(self.scope, self.cx);
        input.input_container.setStyleInline(self.cx.allocator, S.providerInput(0, 32));
        input.input_container.meta.ownership.meta.test_id = id;
        input.node.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 32 }, .flex_shrink = 0 });
        S.tuneInput(&input);
        try group.appendChild(self.cx.allocator, input.node);
        try parent.appendChild(self.cx.allocator, group);
        return input;
    }
    const Capability = struct {
        editor: *Editor,
        kind: enum { reasoning, vision },
        fn changed(self: *@This(), value: ?[]const u8) void {
            const enabled = std.mem.eql(u8, value orelse return, "yes");
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
        const identity = try ui.box(self.cx, .{ .height = .{ .fit = .{} }, .direction = .column, .gap = 3 }, .{});
        try identity.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.label, label));
        try identity.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.note, "手动设置"));
        try row.appendChild(self.cx.allocator, identity);
        try row.appendChild(self.cx.allocator, try ui.spacer(self.cx));
        const state = try self.scope.createState(Capability, .{ .editor = self, .kind = kind });
        const value = try self.scope.createSignal(?[]const u8, if (enabled) "yes" else "no");
        const select = try ui.widgets.Select(.{ .value = ui.split(value, self.cx.on(Capability, state, Capability.changed)), .width = @as(f32, 164), .options = &[_]ui.widgets.SelectOption{ .{ .value = "yes", .label = "支持", .test_id = if (kind == .reasoning) "settings.ai.model.reasoning.yes" else "settings.ai.model.vision.yes" }, .{ .value = "no", .label = "不支持", .test_id = if (kind == .reasoning) "settings.ai.model.reasoning.no" else "settings.ai.model.vision.no" } } }).mount(self.scope, self.cx);
        self.select_open[if (kind == .reasoning) 0 else 1] = select.open;
        select.trigger.setStyleInline(self.cx.allocator, S.providerInput(164, 32));
        select.trigger.meta.ownership.meta.test_id = id;
        try row.appendChild(self.cx.allocator, select.wrapper);
        try parent.appendChild(self.cx.allocator, row);
    }
};
