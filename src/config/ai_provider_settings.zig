//! Native provider forms edit the shared settings draft; saving remains one Config transaction.
const std = @import("std");
const ui = @import("ui");
const config = @import("config.zig");
const runtime = @import("runtime_config.zig");
const Controller = @import("settings_controller.zig").Controller;
const draft = @import("settings_ai_draft.zig");
const controls = @import("settings_parts/settings_controls.zig");
const S = @import("settings_styles.zig");
const ModelEditor = @import("ai_model_editor.zig").Editor;
const Discovery = @import("../ai/model_discovery.zig").Service;
const Brand = @import("../ui/ai_brand.zig");
const DeleteDialog = @import("provider_delete_dialog.zig");

pub const Hooks = struct {
    context: ?*anyopaque = null,
    changed: ?*const fn (*anyopaque) void = null,
    saving: ?*ui.Signal(bool) = null,
};

pub const ProviderView = struct {
    root: *ui.Node,
    scope: *ui.Scope,
    render_scope: ?*ui.Scope = null,
    cx: *ui.Cx,
    controller: *Controller,
    hooks: Hooks,
    disabled: *ui.Signal(bool),
    fields: std.ArrayList(*Field) = .empty,
    badges: std.ArrayList(Badge) = .empty,
    titles: std.ArrayList(Badge) = .empty,
    tips: std.ArrayList(*ui.Signal(bool)) = .empty,
    selects: std.ArrayList(*ui.Signal(bool)) = .empty,
    buttons: std.ArrayList(*ButtonState) = .empty,
    pending: bool = false,
    focus_pending: bool = false,
    focus_address: ?draft.Address = null,
    editor_node: ?*ui.Node = null,
    error_text: []const u8 = "",
    error_node: ?*ui.Node = null,
    header_tip: ?*ui.Signal(bool) = null,
    model_editor: ?*ModelEditor = null,
    discovery: Discovery = .{},
    model_test: Discovery = .{},
    model_test_owner: ?*ModelEditor = null,
    catalog_provider: ?usize = null,
    catalog_signature: u64 = 0,
    catalog_revision: u64 = 0,
    catalog_message: []const u8 = "",
    catalog_detail: [1400]u8 = undefined,

    delete_dialog: ?*DeleteDialog.Dialog = null,
    delete_request: ?struct { provider: usize, model: ?usize } = null,
    edit_request: ?struct { provider: usize, model: ?usize } = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, controller: *Controller) !*ProviderView {
        return mountWithHooks(cx, scope, controller, .{});
    }
    pub fn mountWithHooks(cx: *ui.Cx, scope: *ui.Scope, controller: *Controller, hooks: Hooks) !*ProviderView {
        const self = try scope.allocator.create(ProviderView);
        self.* = .{ .root = try ui.boxStyled(cx, S.column, .{}), .scope = scope, .cx = cx, .controller = controller, .hooks = hooks, .disabled = hooks.saving orelse try scope.createSignal(bool, controller.state() == .saving) };
        self.root.meta.ownership.meta.test_id = "settings.ai.providers";
        try scope.onCleanup(ProviderView, self, cleanup);
        try self.rebuild();
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    fn cleanup(self: *ProviderView) void {
        self.cx.removeAfterLayoutHook(self);
        self.discovery.deinit();
        self.model_test.deinit();
        self.fields.deinit(self.scope.allocator);
        self.badges.deinit(self.scope.allocator);
        self.titles.deinit(self.scope.allocator);
        self.tips.deinit(self.scope.allocator);
        self.selects.deinit(self.scope.allocator);
        self.buttons.deinit(self.scope.allocator);
        self.scope.allocator.destroy(self);
    }
    fn notify(self: *ProviderView) void {
        self.refresh();
        if (self.hooks.changed) |changed| changed(self.hooks.context.?);
        self.cx.requestRedraw();
    }
    fn refresh(self: *ProviderView) void {
        self.disabled.set(self.controller.state() == .saving);
        for (self.buttons.items) |button| button.refresh();
        for (self.fields.items) |field| field.refresh();
        for (self.titles.items) |title| if (title.index < self.controller.model.value.ai.provider_count) {
            title.node.setTextContent(self.cx.allocator, displayName(self.controller.model.value.ai.providers[title.index])) catch {};
        };
        for (self.badges.items) |badge| {
            if (badge.index >= self.controller.model.value.ai.provider_count) continue;
            const p = self.controller.model.value.ai.providers[badge.index];
            badge.node.setTextContent(self.cx.allocator, if (p.enabled) "已启用" else if (draft.eligible(p)) "已停用" else "待配置") catch {};
        }
        if (self.error_node) |node| {
            node.setTextContent(self.cx.allocator, self.error_text) catch {};
            node.setDisplay(if (self.error_text.len != 0) .flex else .none);
        }
    }
    fn schedule(self: *ProviderView) void {
        self.pending = true;
        self.root.markLayoutDirty();
        self.notify();
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *ProviderView = @ptrCast(@alignCast(raw));
        if (self.model_test.busy()) {
            if (self.model_test.finishRequest()) {
                var detail: [1200]u8 = undefined;
                if (self.model_editor) |editor| if (self.model_test_owner == editor) editor.updateTest(if (self.model_test.request_error) |err| if (err == error.Cancelled) "测试已取消" else self.model_test.diagnostic.format(&detail, err) else "模型请求已完成。", false);
                self.model_test_owner = null;
            } else self.cx.scheduleRedrawAfterNs(33 * 1000000);
        }
        if (self.discovery.busy()) {
            if (self.discovery.finishRequest()) {
                const valid = if (self.catalog_provider) |i| i < self.controller.model.value.ai.provider_count and self.catalog_signature == connectionSignature(self.controller.model.value.ai.providers[i]) else false;
                self.catalog_message = if (!valid) "连接配置已变化，请重新获取模型清单。" else if (self.discovery.request_error) |err| switch (err) {
                    error.Cancelled => "已取消获取；可重新获取或手动添加模型。",
                    error.InvalidCatalog => "接口未提供有效模型清单，可手动添加模型。",
                    else => self.discovery.diagnostic.format(&self.catalog_detail, err),
                } else if (self.catalogModels().len == 0) "接口未返回模型，可重新获取或手动添加。" else "模型清单已获取，添加模型时可下拉选择。";
                if (self.model_editor) |editor| editor.updateCatalog(self.catalogFor(editor.provider), self.catalog_message, false) catch {};
                self.pending = true;
            } else self.cx.scheduleRedrawAfterNs(33 * 1000000);
        }
        if (self.delete_dialog) |dialog| {
            if (dialog.done) {
                self.delete_dialog = null;
                dialog.destroy();
                return .needs_layout;
            }
            dialog.resize();
        }
        if (self.delete_request) |target| {
            self.delete_request = null;
            const ai = self.controller.model.value.ai;
            if (target.provider < ai.provider_count) {
                const p = ai.providers[target.provider];
                const dialog = DeleteDialog.Dialog.mount(self.cx, self.scope, .{ .provider = target.provider, .model = target.model, .provider_name = draft.providerName(p), .model_id = if (target.model) |j| if (j < p.model_count) p.models[j].id else "" else "" }, .{ .context = self, .accept = acceptDelete }) catch return .done;
                self.delete_dialog = dialog;
                if (!dialog.modal.portaled) self.root.appendChild(self.cx.allocator, dialog.modal.overlay) catch {};
                return .needs_layout;
            }
        }
        if (self.model_editor) |editor| {
            if (editor.done) {
                if (self.model_test_owner == editor) {
                    self.model_test.cancelRequest();
                    self.model_test_owner = null;
                }
                self.model_editor = null;
                editor.destroy();
                return .needs_layout;
            }
            editor.resize();
        }
        if (self.edit_request) |request| {
            self.edit_request = null;
            const p = self.controller.model.value.ai.providers[request.provider];
            const model: config.AiModel = if (request.model) |j| p.models[j] else .{ .default = p.model_count == 0, .context_window = 0, .efforts = @splat(false) };
            const editor = ModelEditor.mount(self.cx, self.scope, request.provider, request.model, draft.providerName(p), model, self.catalogFor(request.provider), .{ .context = self, .commit = commitModel, .metadata = candidateMetadata, .fetch_models = fetchEditorModels, .test_model = testEditorModel }) catch |err| {
                self.error_text = @errorName(err);
                self.refresh();
                return .done;
            };
            self.model_editor = editor;
            if (!editor.modal.portaled) self.root.appendChild(self.cx.allocator, editor.modal.overlay) catch {};
            return .needs_layout;
        }
        if (self.pending) {
            self.pending = false;
            self.rebuild() catch return .done;
            self.focus_pending = self.focus_address != null;
            return .needs_layout;
        }
        if (self.focus_pending) {
            self.focus_pending = false;
            if (self.editor_node) |node| {
                var moved = false;
                var ancestor = node.parent;
                while (ancestor) |parent| : (ancestor = parent.parent) {
                    if (parent.tag != .scroll) continue;
                    const ctx: *ui.widgets.scroll_area.ScrollEventCtx = @ptrCast(@alignCast(parent.behavior.events.event_context orelse continue));
                    if (ctx.content) |content| {
                        const rect = node.globalRect();
                        const viewport = parent.globalRect();
                        ui.widgets.scrollRectIntoView(ctx.state, content, rect.y - viewport.y + ctx.state.scroll_y, rect.h, .nearest);
                        moved = moved or rect.y < viewport.y - 1 or rect.y + rect.h > viewport.y + viewport.h + 1;
                    }
                }
                if (moved) self.focus_pending = true else {
                    self.cx.setFocus(node);
                    self.focus_address = null;
                }
                self.cx.requestRedraw();
                return .needs_layout;
            }
        }
        return .done;
    }
    /// Parent capture calls this before closing Settings; composition keeps native Escape.
    pub fn consumeEscape(self: *ProviderView) bool {
        if (self.delete_dialog) |dialog| {
            dialog.cancel();
            return true;
        }
        if (self.model_editor) |editor| {
            return editor.consumeEscape();
        }
        if (self.header_tip) |open| if (open.peek()) {
            open.set(false);
            return true;
        };
        for (self.tips.items) |open| if (open.peek()) {
            open.set(false);
            return true;
        };
        for (self.selects.items) |open| if (open.peek()) {
            open.set(false);
            return true;
        };
        const focused = self.cx.focus_manager.getFocused() orelse return false;
        for (self.fields.items) |field| if (field.input.input_container == focused) {
            if (field.input.state.imeIsComposing()) return false;
            field.restore();
            self.cx.setFocus(null);
            return true;
        };
        return false;
    }
    pub fn hasModelEditor(self: *const ProviderView) bool {
        return self.model_editor != null or self.edit_request != null or self.delete_dialog != null or self.delete_request != null;
    }
    pub fn isComposing(self: *const ProviderView) bool {
        if (self.model_editor) |editor| if (editor.isComposing()) return true;
        for (self.fields.items) |field| if (field.input.state.imeIsComposing()) return true;
        return false;
    }
    /// Shared add action used by the V3 Provider card header.
    pub fn mountAddProviderAction(self: *ProviderView, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        const action_scope = try scope.childScope();
        const open = try action_scope.createSignal(bool, false);
        self.header_tip = open;
        const tip = try ui.widgets.Tooltip(.{ .text = "添加服务商", .open = open, .position = .top, .open_delay_ms = 450, .background = S.theme.current().overlay, .text_color = S.theme.current().fg_1, .font_size = 10.5 }).mount(action_scope, cx);
        const action_click = try action_scope.allocator.create(Click);
        action_click.* = .{ .view = self, .action = .add_provider, .provider = 0, .model = 0 };
        try action_scope.onCleanup(Click, action_click, Click.cleanup);
        const button = try ui.widgets.Button(.{ .label = "新增服务提供方", .icon_asset = ui.icons.plus, .icon_size = @as(f32, 14), .a11y_label = "新增服务提供方", .disabled = self.disabled, .on_click = cx.on(Click, action_click, Click.run), .base_style = S.actionControl(false), .hover_style = S.buttonHover() }).mount(action_scope, cx);
        button.meta.ownership.meta.test_id = "settings.ai.add_provider";
        const focus = try action_scope.allocator.create(TipFocus);
        focus.* = .{ .view = self, .open = open };
        try action_scope.onCleanup(TipFocus, focus, TipFocus.cleanup);
        button.behavior.events.on_focus = .{ .callback = TipFocus.focus, .context = focus };
        button.behavior.events.on_blur = .{ .callback = TipFocus.blur, .context = focus };
        try tip.trigger.appendChild(cx.allocator, button);
        return tip.wrapper;
    }
    fn rebuild(self: *ProviderView) !void {
        self.editor_node = null;
        self.error_node = null;
        // Detach invokes blur; release interaction references while its scope is still alive.
        for (self.root.children.items) |child| self.cx.invalidateReferencesTo(child);
        self.fields.clearRetainingCapacity();
        self.badges.clearRetainingCapacity();
        self.titles.clearRetainingCapacity();
        self.tips.clearRetainingCapacity();
        self.selects.clearRetainingCapacity();
        self.buttons.clearRetainingCapacity();
        self.header_tip = null;
        if (self.render_scope) |old| old.dispose();
        self.render_scope = null;
        while (self.root.children.items.len > 0) {
            const child = self.root.children.items[self.root.children.items.len - 1];
            self.cx.detachChild(self.root, child);
            self.cx.destroyDetached(child);
        }
        self.render_scope = try self.scope.childScope();
        const count = self.controller.model.value.ai.provider_count;
        self.root.setStyleInline(self.cx.allocator, .{ .background = S.theme.current().surface_2, .border = .{ .radius = 11 }, .gap = 0, .min_width = 0 });
        const heading = try ui.box(self.cx, .{ .width = .fill(), .min_height = 70, .direction = .row, .padding = .{ .left = 16, .right = 16, .top = 15, .bottom = 14 }, .gap = 10, .align_items = .center, .flex_shrink = 0, .min_width = 0 }, .{});
        const description = try ui.box(self.cx, .{ .width = .fill(), .flex = 1, .direction = .column, .gap = 3, .min_width = 0 }, .{});
        const title = try ui.box(self.cx, .{ .width = .fill(), .direction = .row, .gap = 7, .align_items = .center }, .{});
        try title.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.sparkles, S.theme.current().accent_ink, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }));
        try title.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.title, "服务提供方"));
        try description.appendChild(self.cx.allocator, title);
        try description.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.note, "配置模型服务的连接信息和可用模型。"));
        try heading.appendChild(self.cx.allocator, description);
        try heading.appendChild(self.cx.allocator, try self.mountAddProviderAction(self.render_scope.?, self.cx));
        try self.root.appendChild(self.cx.allocator, heading);
        const list = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(self.render_scope.?, self.cx);
        list.container.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .max_height = 450, .padding = .{ .left = 10, .right = 10, .bottom = 10 }, .min_width = 0, .flex_shrink = 0 });
        list.container.meta.ownership.meta.test_id = "settings.ai.provider_list";
        list.content.setStyleInline(self.cx.allocator, .{ .width = .fill(), .direction = .column, .gap = 6, .min_width = 0, .flex_shrink = 0 });
        for (0..count) |i| try list.content.appendChild(self.cx.allocator, try self.providerCard(i));
        try self.root.appendChild(self.cx.allocator, list.container);
        if (count == 0) {
            const empty = try ui.box(self.cx, .{ .width = .fill(), .direction = .column, .align_items = .center, .padding = .{ .left = 20, .right = 20, .top = 32, .bottom = 32 }, .gap = 0, .flex_shrink = 0 }, .{});
            empty.meta.ownership.meta.test_id = "settings.ai.providers.empty";
            try empty.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.sparkles, S.theme.current().fg_2, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .margin = .{ .bottom = 3 } }));
            const empty_title = try ui.text(self.cx, "添加你的第一个服务提供方", .{ .font_size = 12, .font_weight = 600, .line_height = 20.0 / 12.0, .color = S.theme.current().fg_1 });
            empty_title.setStyleInline(self.cx.allocator, .{ .margin = .{ .top = 8, .bottom = 5 } });
            try empty.appendChild(self.cx.allocator, empty_title);
            try empty.appendChild(self.cx.allocator, try ui.text(self.cx, "支持 Anthropic、OpenAI 兼容接口与 Ollama。", .{ .font_size = 12, .line_height = 1.5, .color = S.theme.current().fg_2 }));
            const add_click = try self.click(.add_provider, 0, 0);
            const add = try ui.widgets.Button(.{ .label = "新增服务提供方", .disabled = self.disabled, .on_click = self.cx.on(Click, add_click, Click.run), .base_style = S.actionControl(false), .hover_style = S.buttonHover() }).mount(self.render_scope.?, self.cx);
            add.meta.ownership.meta.test_id = "settings.ai.providers.empty.add";
            add.setStyleInline(self.cx.allocator, .{ .margin = .{ .top = 15 } });
            try empty.appendChild(self.cx.allocator, add);
            try self.root.appendChild(self.cx.allocator, empty);
        }
        self.error_node = try ui.textStyled(self.cx, S.errorNote, self.error_text);
        self.error_node.?.meta.ownership.meta.test_id = "settings.ai.provider_error";
        try self.root.appendChild(self.cx.allocator, self.error_node.?);
        self.refresh();
    }
    fn connectionSignature(p: config.AiProvider) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(p.name);
        h.update(p.endpoint);
        h.update(p.api_key);
        std.hash.autoHash(&h, p.kind);
        return h.final();
    }
    fn testEditorModel(raw: *anyopaque, provider: usize, model: config.AiModel) void {
        const self: *ProviderView = @ptrCast(@alignCast(raw));
        const editor = self.model_editor orelse return;
        if (self.model_test.busy()) {
            self.model_test.cancelRequest();
            return;
        }
        if (provider >= self.controller.model.value.ai.provider_count) return;
        self.model_test.testModel(self.controller.model.value.ai.providers[provider], model) catch {
            editor.updateTest("无法开始测试，请检查配置。", false);
            return;
        };
        self.model_test_owner = editor;
        editor.updateTest("测试中…", true);
        self.cx.scheduleRedrawAfterNs(33 * 1000000);
    }
    fn fetchEditorModels(raw: *anyopaque, provider: usize) void {
        const self: *ProviderView = @ptrCast(@alignCast(raw));
        self.fetchModels(provider);
        if (self.model_editor) |editor| editor.updateCatalog(&.{}, self.catalog_message, self.discovery.busy()) catch {};
    }
    fn candidateMetadata(raw: *anyopaque, model_id: []const u8) ?@import("../ai/model_discovery.zig").ModelMetadata {
        const self: *ProviderView = @ptrCast(@alignCast(raw));
        return self.discovery.modelMetadata(model_id);
    }
    fn catalogModels(self: *const ProviderView) []const config.AiModel {
        const ai = self.discovery.effective(.{}, self.catalog_revision);
        return if (ai.provider_count > 0) ai.providers[0].models[0..ai.providers[0].model_count] else &.{};
    }
    fn catalogFor(self: *const ProviderView, i: usize) []const config.AiModel {
        if (self.catalog_provider != i or i >= self.controller.model.value.ai.provider_count or self.catalog_signature != connectionSignature(self.controller.model.value.ai.providers[i])) return &.{};
        return self.catalogModels();
    }
    fn fetchModels(self: *ProviderView, i: usize) void {
        if (self.discovery.busy()) {
            self.discovery.cancelRequest();
            self.catalog_message = "正在取消获取…";
            self.schedule();
            return;
        }
        if (i >= self.controller.model.value.ai.provider_count) return;
        const p = self.controller.model.value.ai.providers[i];
        if (!draft.endpointValid(p.endpoint)) {
            self.error_text = "请先填写有效的 API 地址。";
            self.notify();
            return;
        }
        self.catalog_provider = i;
        self.catalog_signature = connectionSignature(p);
        self.catalog_revision +|= 1;
        self.discovery.request(p, self.catalog_revision) catch {
            self.error_text = "无法开始获取模型清单，请重试。";
            self.notify();
            return;
        };
        self.catalog_message = "正在获取模型清单…";
        self.schedule();
    }
    fn providerCard(self: *ProviderView, i: usize) !*ui.Node {
        const p = self.controller.model.value.ai.providers[i];
        const open = self.controller.ai_fields.provider_open.get(i) orelse (i == 0);
        const result = try self.accordion(.provider, i, 0, displayName(p), open, 64, false);
        result.item.meta.ownership.meta.test_id = try self.id(i, null, "card");
        result.item.setStyleInline(self.cx.allocator, .{ .position = .relative, .background = providerBackground(open), .border = .{ .radius = 8 }, .gap = 0, .flex_shrink = 0, .min_width = 0 });
        result.header.setStyleInline(self.cx.allocator, .{ .height = .{ .px = 64 }, .padding = .{ .left = 12, .right = 112, .top = 12, .bottom = 12 }, .gap = 9, .min_width = 0 });
        result.header.removeChild(result.title);
        result.header.removeChild(result.chevron);
        result.chevron.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
        try result.header.appendChild(self.cx.allocator, result.chevron);
        const logo = try Brand.mount(self.cx, Brand.provider(displayName(p), p.endpoint), displayName(p), 30);
        logo.meta.ownership.meta.test_id = try self.id(i, null, "logo");
        try result.header.appendChild(self.cx.allocator, logo);
        const heading = try ui.box(self.cx, .{ .width = .fill(), .flex = 1, .min_width = 0, .direction = .column, .gap = 3 }, .{});
        if (result.title.getText()) |old| {
            var text = old;
            text.font_size = 12;
            text.font_weight = 600;
            text.line_height = 18.0 / 12.0;
            text.text_overflow = .ellipsis;
            result.title.setText(text);
        }
        result.title.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .overflow_hidden = true });
        try self.titles.append(self.scope.allocator, .{ .index = i, .node = result.title });
        try heading.appendChild(self.cx.allocator, result.title);
        var summary_buffer: [96]u8 = undefined;
        const protocol = switch (p.kind) {
            .anthropic => "Anthropic",
            .openai_compat => "OpenAI 兼容",
            .ollama => "Ollama",
        };
        const summary = if (p.model_count == 0) try std.fmt.bufPrint(&summary_buffer, "{s} · 尚未添加模型", .{protocol}) else try std.fmt.bufPrint(&summary_buffer, "{s} · {d} 个模型", .{ protocol, p.model_count });
        try heading.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.note, try controls.owned(self.render_scope.?, summary)));
        try result.header.appendChild(self.cx.allocator, heading);
        const badge = try ui.text(self.cx, "", .{ .font_size = 10, .line_height = 16.0 / 10.0, .color = if (p.enabled) S.theme.current().ok_ink else S.theme.current().fg_2 });
        badge.setStyleInline(self.cx.allocator, .{ .position = .absolute, .inset = .{ .right = .{ .px = 52 }, .top = .{ .px = 21 } }, .padding = .{ .left = 6, .right = 6, .top = 3, .bottom = 3 }, .background = if (p.enabled) S.theme.current().ok_ink.withAlpha(26) else S.theme.current().hover, .border = .{ .radius = 5 } });
        badge.meta.ownership.meta.test_id = try self.id(i, null, "status");
        try self.badges.append(self.scope.allocator, .{ .index = i, .node = badge });
        try result.item.appendChild(self.cx.allocator, badge);
        const toggle_click = try self.click(.toggle_provider, i, 0);
        const toggle = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "启用服务提供方", .disabled = self.disabled, .on_click = self.cx.on(Click, toggle_click, Click.run), .base_style = .{ .width = .{ .px = 30 }, .height = .{ .px = 18 }, .padding = ui.Padding.all(2), .background = if (p.enabled) S.theme.current().accent else S.theme.current().hover, .corner_radius = 9, .border_width = 0 } }).mount(self.render_scope.?, self.cx);
        toggle.setStyleInline(self.cx.allocator, .{ .position = .absolute, .inset = .{ .right = .{ .px = 12 }, .top = .{ .px = 23 } }, .direction = .row, .align_items = .center, .justify = if (p.enabled) .end else .start });
        if (toggle.behavior.interaction.a11y) |*a11y| {
            a11y.role = .switch_role;
            a11y.checked = p.enabled;
        }
        toggle.meta.ownership.meta.test_id = try self.id(i, null, "enabled");
        try toggle.appendChild(self.cx.allocator, try ui.box(self.cx, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .background = ui.Color.WHITE, .border = .{ .radius = 7 }, .flex_shrink = 0, .hit_behavior = .pass_through }, .{}));
        try result.item.appendChild(self.cx.allocator, toggle);
        result.body.setStyleInline(self.cx.allocator, .{ .width = .fill(), .direction = .column, .padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 10 }, .gap = 0, .min_width = 0 });
        const fields = try ui.box(self.cx, .{ .width = .fill(), .direction = .column, .gap = 12, .padding = .{ .bottom = 15 }, .min_width = 0, .flex_shrink = 0 }, .{});
        const pair = try ui.box(self.cx, .{ .width = .fill(), .direction = .row, .align_items = .start, .gap = 14, .min_width = 0, .flex_shrink = 0 }, .{});
        try pair.appendChild(self.cx.allocator, try self.connectionField(i, .name, "服务提供方名称 *", "例如：团队模型服务"));
        const kind_field = try ui.box(self.cx, .{ .width = .fill(), .flex = 1, .min_width = 0, .direction = .column, .gap = 6 }, .{});
        try kind_field.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.label, "API 协议"));
        try kind_field.appendChild(self.cx.allocator, try self.selectKind(i, p.kind));
        try pair.appendChild(self.cx.allocator, kind_field);
        try fields.appendChild(self.cx.allocator, pair);
        try fields.appendChild(self.cx.allocator, try self.connectionField(i, .endpoint, "API 地址 *", "https://api.example.com/v1"));
        try fields.appendChild(self.cx.allocator, try self.connectionField(i, .api_key, if (@import("../ai/provider_config.zig").allowsNoAuth(p.kind, p.endpoint)) "API Key（可选）" else "API Key *", "输入 API Key"));
        try result.body.appendChild(self.cx.allocator, fields);
        const models_heading = try row(self.cx, 44);
        const models_title = try ui.textStyled(self.cx, S.label, try controls.owned(self.render_scope.?, try std.fmt.bufPrint(&summary_buffer, "模型  {d}", .{p.model_count})));
        try models_heading.appendChild(self.cx.allocator, models_title);
        try models_heading.appendChild(self.cx.allocator, try ui.spacer(self.cx));
        try models_heading.appendChild(self.cx.allocator, try self.textAction(.fetch_models, i, if (self.discovery.busy() and self.catalog_provider == i) "取消获取" else "获取模型清单", null, false));
        try models_heading.appendChild(self.cx.allocator, try self.textAction(.add_model, i, "添加模型", ui.icons.plus, false));
        try result.body.appendChild(self.cx.allocator, models_heading);
        if (self.catalog_provider == i and self.catalog_message.len != 0) {
            const message = try ui.textStyled(self.cx, S.note, self.catalog_message);
            message.meta.ownership.meta.test_id = try self.id(i, null, "catalog_status");
            try result.body.appendChild(self.cx.allocator, message);
        }
        if (p.model_count == 0) {
            const empty = try ui.box(self.cx, .{ .width = .fill(), .min_height = 70, .padding = .{ .left = 12, .right = 12, .top = 16, .bottom = 16 }, .direction = .row, .align_items = .center, .gap = 12, .background = S.theme.current().well, .border = .{ .radius = 8 }, .flex_shrink = 0 }, .{});
            try empty.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.box, S.theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }));
            const message = try ui.box(self.cx, .{ .width = .fill(), .flex = 1, .direction = .column, .gap = 3 }, .{});
            try message.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.label, "尚未添加模型"));
            try message.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.note, "获取模型清单后选择，也可手动输入模型。"));
            try empty.appendChild(self.cx.allocator, message);
            const first = try self.textAction(.add_model, i, "添加第一个模型 →", null, false);
            first.meta.ownership.meta.test_id = try self.id(i, null, "first_model");
            first.setStyleInline(self.cx.allocator, .{ .background = ui.Color.TRANSPARENT });
            for (first.children.items) |child| if (child.getText() != null) child.setTextColor(S.theme.current().accent_ink);
            try empty.appendChild(self.cx.allocator, first);
            try result.body.appendChild(self.cx.allocator, empty);
        } else {
            const models = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(self.render_scope.?, self.cx);
            models.container.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .max_height = 190, .flex_shrink = 0, .min_width = 0 });
            models.content.setStyleInline(self.cx.allocator, .{ .width = .fill(), .direction = .column, .gap = 4, .flex_shrink = 0, .min_width = 0 });
            models.container.meta.ownership.meta.test_id = try self.id(i, null, "models");
            for (p.models[0..p.model_count], 0..) |_, j| try models.content.appendChild(self.cx.allocator, try self.modelCard(i, j));
            try result.body.appendChild(self.cx.allocator, models.container);
        }
        const actions = try row(self.cx, 35);
        actions.style.padding.top = 10;
        if (!p.enabled) try actions.appendChild(self.cx.allocator, try self.tooltipOnly(ui.icons.circle_help, "配置完成后，使用卡片右上角开关启用。", 20, try self.id(i, null, "enable_help")));
        try actions.appendChild(self.cx.allocator, try ui.spacer(self.cx));
        try actions.appendChild(self.cx.allocator, try self.textAction(if (self.controller.ai_fields.new_provider == i) .cancel_provider else .delete_provider, i, if (self.controller.ai_fields.new_provider == i) "取消新增" else "删除服务提供方", null, true));
        try result.body.appendChild(self.cx.allocator, actions);
        return result.item;
    }
    fn connectionField(self: *ProviderView, i: usize, field: draft.Field, title: []const u8, placeholder: []const u8) !*ui.Node {
        const r = try ui.box(self.cx, .{ .width = .fill(), .flex = 1, .min_width = 0, .direction = .column, .gap = 6, .flex_shrink = 0 }, .{});
        const label_row = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 18 }, .direction = .row, .align_items = .center, .gap = 8 }, .{});
        try label_row.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.label, title));
        if (field == .api_key) {
            try label_row.appendChild(self.cx.allocator, try self.tooltipOnly(ui.icons.lock, "API Key 存储于 macOS 钥匙串", 18, try self.id(i, null, "keychain")));
        }
        try r.appendChild(self.cx.allocator, label_row);
        const input_wrapper = try self.input(.{ .provider = i, .field = field }, placeholder, 0, 32);
        if (field == .api_key) {
            const key_field = self.fields.items[self.fields.items.len - 1];
            input_wrapper.setStyleInline(self.cx.allocator, .{ .position = .relative });
            key_field.input.input_container.style.padding.right = 36;
            const eye = try ui.widgets.Button(.{ .icon_only = true, .a11y_label = "显示 API Key", .variant = .ghost, .disabled = self.disabled, .on_click = self.cx.on(Field, key_field, Field.reveal), .base_style = .{ .width = .{ .px = 25 }, .height = .{ .px = 26 }, .padding = ui.Padding.ZERO, .background = ui.Color.TRANSPARENT, .border_width = 0, .corner_radius = 7 }, .hover_style = S.buttonHover() }).mount(self.render_scope.?, self.cx);
            eye.setStyleInline(self.cx.allocator, .{ .position = .absolute, .inset = .{ .right = .{ .px = 4 }, .top = .{ .px = 3 } } });
            eye.meta.ownership.meta.test_id = try self.id(i, null, "reveal_key");
            const icon = try ui.iconTint(self.cx, ui.icons.get("eye").?, S.theme.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } });
            try eye.appendChild(self.cx.allocator, icon);
            key_field.eye = eye;
            key_field.eye_icon = icon;
            try input_wrapper.appendChild(self.cx.allocator, eye);
        }
        try r.appendChild(self.cx.allocator, input_wrapper);
        return r;
    }
    fn textAction(self: *ProviderView, action: Action, i: usize, caption: []const u8, icon: ?ui.SvgAsset, danger: bool) !*ui.Node {
        const action_click = try self.click(action, i, 0);
        var style = S.actionControl(danger);
        style.font_size = 11;
        style.height = .{ .px = if (action == .delete_provider or action == .cancel_provider) @as(f32, 25) else @as(f32, 28) };
        if (action == .delete_provider or action == .cancel_provider) {
            style.padding = .{ .left = 6, .right = 6, .top = 5, .bottom = 5 };
            style.font_weight = 400;
        }
        const state = try self.render_scope.?.allocator.create(ButtonState);
        state.* = .{ .view = self, .action = action, .provider = i, .model = 0, .fallback_blocked = false, .disabled = try self.render_scope.?.createSignal(bool, false) };
        try self.render_scope.?.onCleanup(ButtonState, state, ButtonState.cleanup);
        try self.buttons.append(self.scope.allocator, state);
        state.refresh();
        const button = try ui.widgets.Button(.{ .label = caption, .icon_asset = icon, .icon_size = @as(f32, 14), .disabled = state.disabled, .on_click = self.cx.on(Click, action_click, Click.run), .base_style = style, .hover_style = S.buttonHover() }).mount(self.render_scope.?, self.cx);
        button.meta.ownership.meta.test_id = try self.id(i, null, @tagName(action));
        return button;
    }
    fn modelCard(self: *ProviderView, i: usize, j: usize) !*ui.Node {
        const model = self.controller.model.value.ai.providers[i].models[j];
        const root = try ui.box(self.cx, S.modelListRow(), .{});
        root.meta.ownership.meta.test_id = try self.id(i, j, "card");
        const logo = try Brand.mount(self.cx, Brand.model(model.id), Brand.basename(model.id), 30);
        logo.meta.ownership.meta.test_id = try self.id(i, j, "logo");
        try root.appendChild(self.cx.allocator, logo);
        const info = try ui.box(self.cx, .{ .width = .fill(), .flex = 1, .min_width = 0, .direction = .column, .gap = 2 }, .{});
        try root.appendChild(self.cx.allocator, info);
        const model_name = try controls.owned(self.render_scope.?, model.id);
        const edit = try self.click(.edit_model, i, j);
        var name_style = S.textButton();
        name_style.width = .fill();
        name_style.flex = 0;
        name_style.min_width = 0;
        name_style.height = .{ .px = 18 };
        name_style.padding = .{};
        name_style.justify = .start;
        name_style.background = ui.Color.TRANSPARENT;
        const name = try ui.widgets.Button(.{ .variant = .ghost, .hover_style = S.buttonHover(), .label = model_name, .a11y_label = model_name, .disabled = self.disabled, .on_click = self.cx.on(Click, edit, Click.run), .base_style = name_style }).mount(self.render_scope.?, self.cx);
        name.meta.ownership.meta.test_id = try self.id(i, j, "header");
        for (name.children.items) |child| child.setDisplay(.none);
        const name_text = try ui.text(self.cx, model_name, .{ .font_size = 12, .font_weight = 500, .color = S.theme.current().fg_1, .line_height = 1.5, .text_overflow = .ellipsis });
        name_text.meta.ownership.meta.test_id = try self.id(i, j, "name.text");
        name_text.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 18 }, .min_width = 0 });
        try name.appendChild(self.cx.allocator, name_text);
        const name_tip = try self.tooltip(model_name);
        name_tip.content.meta.ownership.meta.test_id = try self.id(i, j, "name.tooltip");
        name_tip.wrapper.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .height = .{ .px = 18 }, .overflow_hidden = true });
        name_tip.trigger.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0 });
        try name_tip.trigger.appendChild(self.cx.allocator, name);
        try self.bindTipFocus(name, name_tip.open.?);
        try info.appendChild(self.cx.allocator, name_tip.wrapper);
        const metadata = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 16 }, .direction = .row, .align_items = .center, .gap = 8, .min_width = 0, .overflow_hidden = true }, .{});
        metadata.meta.ownership.meta.test_id = try self.id(i, j, "metadata");
        try info.appendChild(self.cx.allocator, metadata);
        var buffer: [32]u8 = undefined;
        const context_tip = try self.tooltip(try numberText(model.context_window, &buffer));
        const window = try ui.text(self.cx, try controls.owned(self.render_scope.?, try contextText(model.context_window, &buffer)), .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = S.theme.current().fg_2, .text_overflow = .ellipsis });
        window.setStyleInline(self.cx.allocator, .{ .height = .{ .px = 16 }, .flex_shrink = 0 });
        context_tip.wrapper.setStyleInline(self.cx.allocator, .{ .width = .{ .fit = .{} }, .min_width = 0 });
        context_tip.trigger.setStyleInline(self.cx.allocator, .{ .width = .{ .fit = .{} }, .min_width = 0 });
        try context_tip.trigger.appendChild(self.cx.allocator, window);
        try metadata.appendChild(self.cx.allocator, context_tip.wrapper);
        if (model.reasoning) try metadata.appendChild(self.cx.allocator, try ui.text(self.cx, "推理", .{ .font_size = 10.5, .color = S.theme.current().fg_2, .line_height = 16.0 / 10.5 }));
        if (model.vision) try metadata.appendChild(self.cx.allocator, try ui.text(self.cx, "识图", .{ .font_size = 10.5, .color = S.theme.current().fg_2, .line_height = 16.0 / 10.5 }));
        if (!model.reasoning and !model.vision) try metadata.appendChild(self.cx.allocator, try ui.text(self.cx, "仅文本", .{ .font_size = 10.5, .color = S.theme.current().fg_2, .line_height = 16.0 / 10.5 }));
        try root.appendChild(self.cx.allocator, try self.iconButton(.default_model, i, j, ui.icons.star, if (model.default) "默认模型" else "设为默认模型", 28, model.default, model.default or !self.savedEligible(i, j)));
        try root.appendChild(self.cx.allocator, try self.iconButton(.edit_model, i, j, ui.icons.pencil, "编辑模型", 24, false, false));
        try root.appendChild(self.cx.allocator, try self.iconButton(.delete_model, i, j, ui.icons.trash_2, "删除模型前须选择默认替代项", 24, false, self.modelProtected(i, j)));
        return root;
    }
    fn capabilityIcon(self: *ProviderView, asset: []const u8, caption: []const u8) !*ui.Node {
        const tip = try self.tooltip(caption);
        tip.wrapper.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .flex_shrink = 0 });
        try tip.trigger.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.get(asset).?, S.theme.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } }));
        return tip.wrapper;
    }
    fn commitModel(raw: *anyopaque, i: usize, index: ?usize, model: config.AiModel) !void {
        const self: *ProviderView = @ptrCast(@alignCast(raw));
        if (self.disabled.peek()) return error.SettingsSaving;
        var owned = try runtime.Snapshot.init(self.scope.allocator, self.controller.model.value);
        defer owned.deinit();
        const p = &owned.value.ai.providers[i];
        const j = index orelse p.model_count;
        if (index == null) {
            const next = try owned.arena.allocator().alloc(config.AiModel, p.model_count + 1);
            @memcpy(next[0..p.model_count], p.models[0..p.model_count]);
            next[j] = model;
            p.models = next;
            p.model_count += 1;
        } else p.models[j] = model;
        try draft.assign(&owned.value.ai, .{ .provider = i, .model = j, .field = .model_id }, model.id);
        if (model.context_window == 0) return error.InvalidContextWindow;
        if (!draft.modelValid(model)) return error.LastEffortRequired;
        if (model.default) for (p.models[0..p.model_count], 0..) |*other, k| {
            other.default = k == j;
        };
        var defaults: usize = 0;
        for (p.models[0..p.model_count]) |other| if (other.default) {
            defaults += 1;
        };
        if (defaults != 1) return error.DefaultProtected;
        try self.controller.editProviders(owned.value.ai);
        self.error_text = "";
        self.schedule();
    }
    fn acceptDelete(raw: *anyopaque, dialog: *DeleteDialog.Dialog) bool {
        const self: *ProviderView = @ptrCast(@alignCast(raw));
        const target = dialog.target;
        const ai = self.controller.model.value.ai;
        if (target.provider >= ai.provider_count or !std.mem.eql(u8, target.provider_name, draft.providerName(ai.providers[target.provider]))) {
            dialog.fail("配置已改变，请关闭后重新选择。");
            return false;
        }
        const p = ai.providers[target.provider];
        if (target.model) |j| if (j >= p.model_count or !std.mem.eql(u8, target.model_id, p.models[j].id)) {
            dialog.fail("模型已改变，请关闭后重新选择。");
            return false;
        };
        const before = if (target.model != null) p.model_count else ai.provider_count;
        var action_click = Click{ .view = self, .action = if (target.model != null) .delete_model else .delete_provider, .provider = target.provider, .model = target.model orelse 0, .confirmed = true };
        action_click.run();
        const after = if (target.model != null) self.controller.model.value.ai.providers[target.provider].model_count else self.controller.model.value.ai.provider_count;
        if (after == before) {
            dialog.fail(if (self.error_text.len != 0) self.error_text else "当前配置不能删除，请先选择合法替代项。");
            return false;
        }
        return true;
    }
    fn savedEligible(self: *ProviderView, i: usize, j: ?usize) bool {
        const ai = self.controller.model.value.ai;
        if (i >= ai.provider_count) return false;
        const p = ai.providers[i];
        if (j) |index| return index < p.model_count and draft.modelValid(p.models[index]);
        return p.enabled and draft.eligible(p);
    }
    fn modelProtected(self: *ProviderView, i: usize, j: usize) bool {
        const p = self.controller.model.value.ai.providers[i];
        return (p.enabled and p.model_count <= 1) or (p.model_count > 1 and p.models[j].default);
    }
    fn input(self: *ProviderView, address: draft.Address, placeholder: []const u8, width: f32, height: f32) !*ui.Node {
        const scope = self.render_scope.?;
        const field = try scope.allocator.create(Field);
        errdefer scope.allocator.destroy(field);
        var buffer: [32]u8 = undefined;
        const initial = if (self.controller.ai_fields.get(address)) |raw| raw.input else try draft.fieldValue(self.controller.model.value.ai, address, &buffer);
        field.* = .{ .view = self, .address = address, .text = try scope.createText(initial, .{}), .input = undefined, .error_node = undefined };
        try scope.onCleanup(Field, field, Field.cleanup);
        field.input = try ui.widgets.Input(.{ .value = field.text, .input_type = @as(ui.widgets.InputType, if (address.field == .api_key) .password else .text), .placeholder = placeholder, .disabled = self.disabled, .on_change = self.cx.on(Field, field, Field.edit), .on_submit = self.cx.on(Field, field, Field.submit) }).mountResult(scope, self.cx);
        const input_style = S.providerInput(width, height);
        field.input.input_container.setStyleInline(self.cx.allocator, input_style);
        field.input.node.style.width = if (width > 0) .{ .px = width } else .fill();
        field.input.node.style.flex = if (width > 0) 0 else 1;
        field.input.node.setStyleInline(self.cx.allocator, .{ .min_width = 0, .flex_shrink = 0 });
        field.input.input_container.meta.ownership.meta.test_id = try self.id(address.provider, if (address.field == .model_id or address.field == .context_window) address.model else null, @tagName(address.field));
        field.input.input_container.behavior.interaction.a11y = .{ .role = .textbox, .label = placeholder };
        S.tuneInput(&field.input);
        field.input.state.font_size = 12;
        field.input.state.line_height = 18;
        if (field.input.state.text_display_node) |display| tuneProviderText(display);
        const wrapper = try ui.boxStyled(self.cx, S.column, .{});
        wrapper.behavior.events.on_event = Field.event;
        wrapper.behavior.events.event_context = field;
        wrapper.style.gap = 2;
        wrapper.style.width = if (width > 0) .{ .px = width } else .fill();
        wrapper.style.flex = if (width > 0) 0 else 1;
        field.error_node = try ui.textStyled(self.cx, S.errorNote, "");
        field.error_node.style.width = .fill();
        if (field.error_node.getText()) |old| {
            var props = old;
            props.wrap = .word;
            field.error_node.setText(props);
        }
        field.error_node.meta.ownership.meta.test_id = try self.id(address.provider, if (address.field == .model_id or address.field == .context_window) address.model else null, try controls.stableId(scope, @tagName(address.field), ".error"));
        try wrapper.appendChild(self.cx.allocator, field.input.node);
        try wrapper.appendChild(self.cx.allocator, field.error_node);
        try self.fields.append(self.scope.allocator, field);
        if (self.focus_address) |target| {
            if (target.eql(address)) self.editor_node = field.input.input_container;
        }
        field.refresh();
        return wrapper;
    }
    fn selectKind(self: *ProviderView, i: usize, kind: config.ProviderKind) !*ui.Node {
        const action_click = try self.click(.kind, i, 0);
        const value = try self.render_scope.?.createSignal(?[]const u8, @tagName(kind));
        const select = try ui.widgets.Select(.{ .value = ui.split(value, self.cx.on(Click, action_click, Click.kind)), .width = @as(f32, 1), .disabled = self.disabled, .options = &[_]ui.widgets.SelectOption{ .{ .value = "anthropic", .label = "Anthropic" }, .{ .value = "openai_compat", .label = "OpenAI 兼容" }, .{ .value = "ollama", .label = "Ollama" } } }).mount(self.render_scope.?, self.cx);
        select.trigger.setStyleInline(self.cx.allocator, S.providerInput(0, 32));
        select.wrapper.style.width = .fill();
        select.wrapper.style.flex = 1;
        if (select.trigger.parent) |trigger_owner| trigger_owner.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .flex = 1 });
        select.trigger.meta.ownership.meta.test_id = try self.id(i, null, "kind");
        S.tuneSelect(select);
        tuneProviderText(select.content_slot);
        if (select.open) |open| try self.selects.append(self.scope.allocator, open);
        return select.wrapper;
    }
    const Accordion = ui.widgets.AccordionItemResult;
    fn accordion(self: *ProviderView, kind: Fold.Kind, i: usize, j: usize, title: []const u8, open: bool, height: f32, section: bool) !Accordion {
        const scope = self.render_scope.?;
        const fold = try scope.allocator.create(Fold);
        fold.* = .{ .view = self, .kind = kind, .provider = i, .model = j, .open = try scope.createSignal(bool, open) };
        try scope.onCleanup(Fold, fold, Fold.cleanup);
        const result = try ui.widgets.AccordionItem(.{ .title = try controls.owned(scope, title), .expanded = ui.split(fold.open, self.cx.on(Fold, fold, Fold.change)), .variant = .ghost }).mount(scope, self.cx);
        result.item.setStyleInline(self.cx.allocator, if (section) S.section(undefined) else S.column(undefined));
        result.item.style.gap = if (open) (if (kind == .provider) @as(f32, 4) else 6) else 0;
        result.header.setStyleInline(self.cx.allocator, S.sectionHeader(undefined));
        result.header.style.height = .{ .px = height };
        result.header.style.padding = .ZERO;
        result.header.meta.ownership.meta.test_id = try self.id(i, if (kind == .model) j else null, switch (kind) {
            .provider => "header",
            .connection => "connection.header",
            .model => "header",
            .existing => "existing.header",
        });
        result.title.setStyleInline(self.cx.allocator, .{ .font_size = if (kind == .model) @as(f32, 11.5) else 12, .font_weight = 400, .min_width = 0 });
        if (result.title.getText()) |old| {
            var text = old;
            text.font_size = if (kind == .model) 11.5 else 12;
            text.font_weight = if (kind == .model) 400 else 500;
            text.line_height = if (kind == .model) 17.0 / 11.5 else 1.5;
            text.color = S.theme.current().fg_1;
            result.title.setText(text);
        }
        result.chevron.style.width = .{ .px = 14 };
        result.chevron.style.height = .{ .px = 14 };
        result.header.removeChild(result.chevron);
        if (kind == .provider or kind == .model) {
            try result.header.insertChildBefore(self.cx.allocator, result.chevron, result.title);
        } else try result.header.appendChild(self.cx.allocator, result.chevron);
        result.body.setStyleInline(self.cx.allocator, S.column(undefined));
        result.body.style.padding = .ZERO;
        result.body.style.gap = if (kind == .provider) 4 else 6;
        return result;
    }
    fn iconButton(self: *ProviderView, action: Action, i: usize, j: usize, icon: ui.SvgAsset, help: []const u8, size: f32, active: bool, blocked: bool) !*ui.Node {
        const scope = self.render_scope.?;
        const action_click = try self.click(action, i, j);
        const tip = try self.tooltip(help);
        var style = S.button(size, false);
        style.background = if (active) S.theme.current().selection else if (blocked) S.theme.current().well else ui.Color.TRANSPARENT;
        style.text_color = if (active) S.theme.current().accent else S.theme.current().fg_2;
        const state = try scope.allocator.create(ButtonState);
        state.* = .{ .view = self, .action = action, .provider = i, .model = j, .fallback_blocked = blocked, .disabled = try scope.createSignal(bool, blocked or self.disabled.peek()) };
        try scope.onCleanup(ButtonState, state, ButtonState.cleanup);
        try self.buttons.append(self.scope.allocator, state);
        try scope.createEffect(.{ .state = state }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.state.view.disabled.get();
                ctx.state.refresh();
            }
        }.run);
        const disabled = state.disabled;
        const is_default = action == .default_model;
        if (is_default) {
            style.width = .{ .px = if (active) 49 else 25 };
            style.height = .{ .px = 26 };
            style.font_size = 10;
            style.font_weight = 400;
            style.padding = .{ .left = 6, .right = 6 };
            style.gap = 4;
            style.background = ui.Color.TRANSPARENT;
        }
        const button = try ui.widgets.Button(.{ .label = if (is_default and active) "默认" else "", .icon_asset = icon, .icon_only = !is_default or !active, .icon_size = @as(f32, 14), .a11y_label = help, .disabled = disabled, .on_click = self.cx.on(Click, action_click, Click.run), .base_style = style, .hover_style = S.buttonHover() }).mount(scope, self.cx);
        button.meta.ownership.meta.test_id = try self.id(i, switch (action) {
            .reasoning, .vision, .default_model, .delete_model, .cancel_model, .edit_model => j,
            else => null,
        }, @tagName(action));
        try tip.trigger.appendChild(self.cx.allocator, button);
        try self.bindTipFocus(button, tip.open.?);
        return tip.wrapper;
    }
    fn tooltipOnly(self: *ProviderView, icon: ui.SvgAsset, help: []const u8, size: f32, test_id: []const u8) !*ui.Node {
        const tip = try self.tooltip(help);
        var style = S.button(size, false);
        style.background = ui.Color.TRANSPARENT;
        const button = try ui.widgets.Button(.{ .icon_asset = icon, .icon_only = true, .icon_size = @as(f32, 14), .a11y_label = help, .variant = .ghost, .base_style = style, .hover_style = S.buttonHover() }).mount(self.render_scope.?, self.cx);
        button.meta.ownership.meta.test_id = test_id;
        tip.content.meta.ownership.meta.test_id = try controls.stableId(self.render_scope.?, test_id, ".tooltip");
        try tip.trigger.appendChild(self.cx.allocator, button);
        try self.bindTipFocus(button, tip.open.?);
        return tip.wrapper;
    }
    fn tooltip(self: *ProviderView, text: []const u8) !ui.widgets.TooltipResult {
        const open = try self.render_scope.?.createSignal(bool, false);
        const tip = try ui.widgets.Tooltip(.{ .text = try controls.owned(self.render_scope.?, text), .open = open, .position = .top, .open_delay_ms = 450, .background = S.theme.current().overlay, .text_color = S.theme.current().fg_1, .font_size = 10.5 }).mount(self.render_scope.?, self.cx);
        tip.content.setStyleInline(self.cx.allocator, S.fieldHelp(undefined));
        for (tip.content.children.items) |tip_label| if (tip_label.getText()) |old| {
            var props = old;
            props.wrap = .word;
            props.line_height = 16.0 / 10.5;
            tip_label.setText(props);
            tip_label.setStyleInline(self.cx.allocator, .{ .width = .fill(), .max_width = S.geometry.help_width - 20, .min_width = 0 });
        };
        try self.tips.append(self.scope.allocator, open);
        return tip;
    }
    fn bindTipFocus(self: *ProviderView, node: *ui.Node, open: *ui.Signal(bool)) !void {
        const tip = try self.render_scope.?.allocator.create(TipFocus);
        tip.* = .{ .view = self, .open = open };
        try self.render_scope.?.onCleanup(TipFocus, tip, TipFocus.cleanup);
        node.behavior.events.on_focus = .{ .callback = TipFocus.focus, .context = tip };
        node.behavior.events.on_blur = .{ .callback = TipFocus.blur, .context = tip };
    }
    fn click(self: *ProviderView, action: Action, i: usize, j: usize) !*Click {
        const c = try self.render_scope.?.allocator.create(Click);
        c.* = .{ .view = self, .action = action, .provider = i, .model = j };
        try self.render_scope.?.onCleanup(Click, c, Click.cleanup);
        return c;
    }
    fn label(self: *ProviderView, text: []const u8, width: f32) !*ui.Node {
        const node = try ui.textStyled(self.cx, S.note, text);
        node.style.width = .{ .px = width };
        node.style.flex_shrink = 0;
        return node;
    }
    fn id(self: *ProviderView, i: usize, j: ?usize, suffix: []const u8) ![]const u8 {
        var buffer: [192]u8 = undefined;
        const text = if (j) |index| try std.fmt.bufPrint(&buffer, "settings.ai.provider.{d}.model.{d}.{s}", .{ i, index, suffix }) else try std.fmt.bufPrint(&buffer, "settings.ai.provider.{d}.{s}", .{ i, suffix });
        return controls.owned(self.render_scope.?, text);
    }
};

const Badge = struct { index: usize, node: *ui.Node };
const ButtonState = struct {
    view: *ProviderView,
    action: Action,
    provider: usize,
    model: usize,
    fallback_blocked: bool,
    disabled: *ui.Signal(bool),
    fn cleanup(self: *ButtonState) void {
        self.view.scope.allocator.destroy(self);
    }
    fn refresh(self: *ButtonState) void {
        const ai = self.view.controller.model.value.ai;
        const blocked = switch (self.action) {
            .fetch_models => self.view.discovery.busy() and self.view.catalog_provider != self.provider,
            .default_provider => self.provider >= ai.provider_count or std.mem.eql(u8, ai.default_provider, draft.providerName(ai.providers[self.provider])) or !self.view.savedEligible(self.provider, null),
            .default_model => self.provider >= ai.provider_count or self.model >= ai.providers[self.provider].model_count or ai.providers[self.provider].models[self.model].default or !self.view.savedEligible(self.provider, self.model),
            .delete_model => self.provider >= ai.provider_count or self.model >= ai.providers[self.provider].model_count or self.view.modelProtected(self.provider, self.model),
            .delete_provider => self.provider >= ai.provider_count or (ai.providers[self.provider].enabled and std.mem.eql(u8, ai.default_provider, draft.providerName(ai.providers[self.provider]))),
            else => self.fallback_blocked,
        };
        self.disabled.set(self.view.disabled.peek() or blocked);
    }
};
const Field = struct {
    view: *ProviderView,
    address: draft.Address,
    text: *ui.Signal([]const u8),
    input: ui.widgets.input.InputResult,
    error_node: *ui.Node,
    revealed: bool = false,
    eye: ?*ui.Node = null,
    eye_icon: ?*ui.Node = null,
    fn reveal(self: *Field) void {
        if (self.view.disabled.peek()) return;
        self.revealed = !self.revealed;
        self.input.state.input_type = if (self.revealed) .text else .password;
        self.input.state.dirty = true;
        const asset = ui.icons.get(if (self.revealed) "eye-off" else "eye").?;
        if (self.eye_icon) |icon| if (asset.icon_id) |id| if (asset.pickRep(14)) |rep| icon.setIcon(.{ .icon_id = id, .rep = rep, .tint = S.theme.current().fg_2 });
        if (self.eye) |eye| eye.behavior.interaction.a11y = .{ .role = .button, .label = if (self.revealed) "隐藏 API Key" else "显示 API Key" };
        self.view.cx.requestRedraw();
    }
    fn cleanup(self: *Field) void {
        self.view.scope.allocator.destroy(self);
    }
    fn refresh(self: *Field) void {
        const raw = self.view.controller.ai_fields.get(self.address);
        const problem = if (raw) |value| value.problem else null;
        self.error_node.setTextContent(self.view.cx.allocator, if (problem) |err| draft.problemText(err) else "") catch {};
        self.error_node.setDisplay(if (problem != null) .flex else .none);
        self.input.input_container.setBorderWidth(0);
        self.input.input_container.setBackground(if (problem != null) S.theme.current().danger.withAlpha(23) else S.theme.current().well);
        self.input.input_container.setBorderColor(if (problem != null) S.theme.current().danger_ink else S.theme.current().well_border);
    }
    fn edit(self: *Field, text: []const u8) void {
        if (self.view.disabled.peek()) return;
        self.view.controller.editAiRaw(self.address, text) catch {};
        self.view.error_text = "";
        self.view.notify();
    }
    fn submit(self: *Field, text: []const u8) void {
        if (self.input.state.imeIsComposing()) return;
        self.edit(text);
    }
    fn restore(self: *Field) void {
        var buffer: [32]u8 = undefined;
        const text = draft.fieldValue(self.view.controller.model.value.ai, self.address, &buffer) catch return;
        self.text.set(text);
        self.view.controller.cancelAiRaw(self.address);
        self.view.notify();
    }
    fn event(event_value: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Field = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event_value == .key_down and event_value.key_down.key == .escape and !self.input.state.imeIsComposing()) {
            self.restore();
            return .stop;
        }
        return .ignored;
    }
};
const Fold = struct {
    const Kind = enum { provider, connection, model, existing };
    view: *ProviderView,
    kind: Kind,
    provider: usize,
    model: usize,
    open: *ui.Signal(bool),
    fn cleanup(self: *Fold) void {
        self.view.scope.allocator.destroy(self);
    }
    fn change(self: *Fold, value: bool) void {
        if (self.view.disabled.peek()) return;
        const state = &self.view.controller.ai_fields;
        switch (self.kind) {
            .provider => state.provider_open.put(self.view.scope.allocator, self.provider, value) catch return,
            .connection => state.connection_open.put(self.view.scope.allocator, self.provider, value) catch return,
            .model => {
                // At most one model editor per Provider; expanding never edits model data.
                if (value) {
                    const count = self.view.controller.model.value.ai.providers[self.provider].model_count;
                    for (0..count) |j| state.model_open.put(self.view.scope.allocator, draft.modelKey(self.provider, j), false) catch return;
                }
                state.model_open.put(self.view.scope.allocator, draft.modelKey(self.provider, self.model), value) catch return;
            },
            .existing => state.existing_open = value,
        }
        self.open.set(value);
        if (self.kind != .existing) self.view.schedule();
    }
};
const Action = enum { fetch_models, toggle_provider, edit_model, add_provider, cancel_provider, delete_provider, add_model, cancel_model, delete_model, default_provider, default_model, reasoning, vision, effort0, effort1, effort2, effort3, effort4, kind };
const Click = struct {
    view: *ProviderView,
    action: Action,
    provider: usize,
    model: usize,
    confirmed: bool = false,
    fn cleanup(self: *Click) void {
        self.view.scope.allocator.destroy(self);
    }
    fn kind(self: *Click, selected: ?[]const u8) void {
        if (self.view.disabled.peek()) return;
        const selected_kind = std.meta.stringToEnum(config.ProviderKind, selected orelse return) orelse return;
        var owned = runtime.Snapshot.init(self.view.scope.allocator, self.view.controller.model.value) catch return;
        defer owned.deinit();
        const p = &owned.value.ai.providers[self.provider];
        p.kind = selected_kind;
        self.view.controller.editProviders(owned.value.ai) catch return;
        self.view.schedule();
    }
    fn run(self: *Click) void {
        const v = self.view;
        if (v.disabled.peek()) return;
        if (self.action == .fetch_models) {
            v.fetchModels(self.provider);
            return;
        }
        if ((self.action == .delete_provider or self.action == .delete_model) and !self.confirmed) {
            if (v.hasModelEditor()) return;
            v.delete_request = .{ .provider = self.provider, .model = if (self.action == .delete_model) self.model else null };
            v.root.markLayoutDirty();
            v.cx.requestRedraw();
            return;
        }
        if (self.action == .edit_model or self.action == .add_model) {
            if (v.model_editor != null or v.edit_request != null) return;
            v.edit_request = .{ .provider = self.provider, .model = if (self.action == .edit_model) self.model else null };
            v.root.markLayoutDirty();
            v.cx.requestRedraw();
            return;
        }
        var owned = runtime.Snapshot.init(v.scope.allocator, v.controller.model.value) catch return;
        defer owned.deinit();
        const allocator = owned.arena.allocator();
        const ai = &owned.value.ai;
        switch (self.action) {
            .add_provider => {
                if (v.controller.ai_fields.new_provider != null) return;
                const i = ai.provider_count;
                const next = allocator.alloc(config.AiProvider, i + 1) catch return;
                @memcpy(next[0..i], ai.providers[0..i]);
                next[i] = .{};
                ai.providers = next;
                ai.provider_count += 1;
                v.controller.editProviders(ai.*) catch return;
                v.controller.ai_fields.new_provider = i;
                v.controller.ai_fields.provider_open.put(v.scope.allocator, i, true) catch return;
                v.controller.ai_fields.connection_open.put(v.scope.allocator, i, true) catch return;
                v.controller.editAiRaw(.{ .provider = i, .field = .name }, "") catch {};
                v.focus_address = .{ .provider = i, .field = .name };
            },
            .cancel_provider, .delete_provider => {
                if (self.provider >= ai.provider_count) return;
                if (self.action == .delete_provider and ai.providers[self.provider].enabled and std.mem.eql(u8, ai.default_provider, draft.providerName(ai.providers[self.provider]))) {
                    v.error_text = draft.problemText(error.DefaultProtected);
                    v.notify();
                    return;
                }
                std.mem.copyForwards(config.AiProvider, ai.providers[self.provider..], ai.providers[self.provider + 1 .. ai.provider_count]);
                ai.provider_count -= 1;
                ai.providers = ai.providers[0..ai.provider_count];
                v.controller.editProviders(ai.*) catch return;
                v.controller.ai_fields.removeProvider(v.scope.allocator, self.provider);
                v.controller.refreshDirty();
            },
            else => {
                if (self.provider >= ai.provider_count) return;
                const p = &ai.providers[self.provider];
                switch (self.action) {
                    .add_model => {
                        if (v.controller.ai_fields.new_model != null) return;
                        const j = p.model_count;
                        const next = allocator.alloc(config.AiModel, j + 1) catch return;
                        @memcpy(next[0..j], p.models[0..j]);
                        next[j] = .{};
                        // A first model is the Provider's local default, without changing global default Provider.
                        next[j].default = j == 0;
                        p.models = next;
                        p.model_count += 1;
                        p.enabled = false;
                        v.controller.editProviders(ai.*) catch return;
                        v.controller.ai_fields.new_model = .{ .provider = self.provider, .model = j };
                        v.controller.ai_fields.model_open.put(v.scope.allocator, draft.modelKey(self.provider, j), true) catch return;
                        v.controller.editAiRaw(.{ .provider = self.provider, .model = j, .field = .model_id }, "") catch {};
                        v.controller.editAiRaw(.{ .provider = self.provider, .model = j, .field = .context_window }, "0") catch {};
                        v.focus_address = .{ .provider = self.provider, .model = j, .field = .model_id };
                    },
                    .delete_model, .cancel_model => {
                        if (self.model >= p.model_count) return;
                        if (self.action == .delete_model and v.modelProtected(self.provider, self.model)) {
                            v.error_text = draft.problemText(error.DefaultProtected);
                            v.notify();
                            return;
                        }
                        std.mem.copyForwards(config.AiModel, p.models[self.model..], p.models[self.model + 1 .. p.model_count]);
                        p.model_count -= 1;
                        p.models = p.models[0..p.model_count];
                        v.controller.editProviders(ai.*) catch return;
                        v.controller.ai_fields.removeModel(v.scope.allocator, self.provider, self.model);
                        v.controller.refreshDirty();
                    },
                    .toggle_provider => {
                        if (!p.enabled) for (v.controller.ai_fields.fields.items) |raw| {
                            if (raw.address.provider == self.provider and raw.problem != null) {
                                v.error_text = draft.problemText(raw.problem.?);
                                v.controller.ai_fields.provider_open.put(v.scope.allocator, self.provider, true) catch {};
                                v.schedule();
                                return;
                            }
                        };
                        draft.setEnabled(ai, self.provider, !p.enabled) catch |err| {
                            v.error_text = draft.problemText(err);
                            v.controller.ai_fields.provider_open.put(v.scope.allocator, self.provider, true) catch {};
                            v.schedule();
                            return;
                        };
                        v.controller.editProviders(ai.*) catch return;
                    },
                    .default_provider => {
                        if (!v.savedEligible(self.provider, null)) return;
                        ai.default_provider = draft.providerName(p.*);
                        v.controller.editProviders(ai.*) catch return;
                    },
                    .default_model => {
                        if (!v.savedEligible(self.provider, self.model)) return;
                        for (p.models[0..p.model_count]) |*model| model.default = false;
                        p.models[self.model].default = true;
                        v.controller.editProviders(ai.*) catch return;
                    },
                    .reasoning, .vision, .effort0, .effort1, .effort2, .effort3, .effort4 => {
                        const model = &p.models[self.model];
                        switch (self.action) {
                            .reasoning => model.reasoning = !model.reasoning,
                            .vision => model.vision = !model.vision,
                            else => {
                                const k = @backingInt(self.action) - @backingInt(Action.effort0);
                                var count: usize = 0;
                                for (model.efforts) |enabled| if (enabled) {
                                    count += 1;
                                };
                                if (model.reasoning and model.efforts[k] and count == 1) {
                                    v.error_text = draft.problemText(error.LastEffortRequired);
                                    v.notify();
                                    return;
                                }
                                model.efforts[k] = !model.efforts[k];
                            },
                        }
                        if (model.reasoning and !draft.modelValid(model.*)) {
                            v.error_text = draft.problemText(error.LastEffortRequired);
                            v.notify();
                            return;
                        }
                        v.controller.editProviders(ai.*) catch return;
                    },
                    else => return,
                }
            },
        }
        v.error_text = "";
        v.schedule();
    }
};
const TipFocus = struct {
    view: *ProviderView,
    open: *ui.Signal(bool),
    fn cleanup(self: *TipFocus) void {
        self.view.scope.allocator.destroy(self);
    }
    fn focus(raw: *anyopaque) void {
        const self: *TipFocus = @ptrCast(@alignCast(raw));
        self.open.set(true);
    }
    fn blur(raw: *anyopaque) void {
        const self: *TipFocus = @ptrCast(@alignCast(raw));
        self.open.set(false);
    }
};
fn row(cx: *ui.Cx, height: f32) !*ui.Node {
    return ui.box(cx, .{ .width = .fill(), .height = .{ .px = height }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0, .min_width = 0 }, .{});
}
fn tuneProviderText(node: *ui.Node) void {
    if (node.getText()) |old| {
        var text = old;
        text.font_size = 12;
        text.font_weight = 400;
        text.line_height = 1.5;
        text.color = S.theme.current().fg_1;
        node.setText(text);
    }
    for (node.children.items) |child| tuneProviderText(child);
}

fn providerBackground(open: bool) ui.Color {
    const c = S.theme.current();
    if (!open) return c.well;
    return ui.Color.lerp(c.well, c.surface_2, 0.38);
}

fn displayName(p: config.AiProvider) []const u8 {
    if (p.name.len == 0) return "新服务提供方";
    return if (p.name.len != 0 and !std.mem.eql(u8, p.name, @tagName(p.kind))) p.name else switch (p.kind) {
        .anthropic => "Anthropic",
        .openai_compat => "OpenAI 兼容",
        .ollama => "Ollama",
    };
}
fn numberText(value: u32, buffer: []u8) ![]const u8 {
    var plain: [16]u8 = undefined;
    const text = try std.fmt.bufPrint(&plain, "{d}", .{value});
    var n: usize = 0;
    for (text, 0..) |char, index| {
        if (index > 0 and (text.len - index) % 3 == 0) {
            buffer[n] = ',';
            n += 1;
        }
        buffer[n] = char;
        n += 1;
    }
    return buffer[0..n];
}

fn contextText(value: u32, buffer: []u8) ![]const u8 {
    if (value >= 1_000_000) return std.fmt.bufPrint(buffer, "{d:.1}M 上下文", .{@as(f64, @floatFromInt(value)) / 1_000_000});
    if (value >= 1000) return std.fmt.bufPrint(buffer, "{d:.0}K 上下文", .{@as(f64, @floatFromInt(value)) / 1000});
    return std.fmt.bufPrint(buffer, "{d} 上下文", .{value});
}

test "global material expanded provider preserves mixed surface alpha" {
    const theme = S.theme;
    const saved = theme.materialParameters();
    defer _ = theme.setMaterialParameters(saved.transparency, saved.blur);
    for ([_]f32{ 0, 50, 100 }) |percent| {
        _ = theme.setMaterialParameters(percent, 0);
        const c = theme.current();
        try std.testing.expectEqual(c.well, providerBackground(false));
        try std.testing.expectEqual(ui.Color.lerp(c.well, c.surface_2, 0.38), providerBackground(true));
        if (percent > 0) try std.testing.expect(providerBackground(true).a < 255);
    }
}
