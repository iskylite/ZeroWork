//! Native provider forms edit the shared settings draft; saving remains one Config transaction.
const std = @import("std");
const ui = @import("ui");
const config = @import("config.zig");
const runtime = @import("runtime_config.zig");
const Controller = @import("settings_controller.zig").Controller;
const draft = @import("settings_ai_draft.zig");
const controls = @import("settings_parts/settings_controls.zig");
const S = @import("settings_styles.zig");

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
        self.fields.deinit(self.scope.allocator);
        self.badges.deinit(self.scope.allocator);
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
        for (self.badges.items) |badge| {
            const p = self.controller.model.value.ai.providers[badge.index];
            const changed = badge.index >= self.controller.original.value.ai.provider_count or !@import("settings_schema.zig").same(p, self.controller.original.value.ai.providers[badge.index]);
            badge.node.setTextContent(self.cx.allocator, if (changed) "待保存" else if (p.enabled and draft.eligible(p)) "已配置" else "禁用") catch {};
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
    pub fn isComposing(self: *const ProviderView) bool {
        for (self.fields.items) |field| if (field.input.state.imeIsComposing()) return true;
        return false;
    }
    /// The Figma additional-Provider state has no entry drawn in its baseline.
    /// Its missing entry is placed beside category help without adding a content row.
    pub fn mountAddProviderAction(self: *ProviderView, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        const action_scope = try scope.childScope();
        const open = try action_scope.createSignal(bool, false);
        self.header_tip = open;
        const tip = try ui.widgets.Tooltip(.{ .text = "添加服务商", .open = open, .position = .top, .open_delay_ms = 450, .background = S.theme.current().overlay, .text_color = S.theme.current().fg_1, .font_size = 10.5 }).mount(action_scope, cx);
        const action_click = try action_scope.allocator.create(Click);
        action_click.* = .{ .view = self, .action = .add_provider, .provider = 0, .model = 0 };
        try action_scope.onCleanup(Click, action_click, Click.cleanup);
        const button = try ui.widgets.Button(.{ .icon_asset = ui.icons.plus, .icon_only = true, .icon_size = @as(f32, 16), .a11y_label = "添加服务商", .disabled = self.disabled, .on_click = cx.on(Click, action_click, Click.run), .base_style = S.button(S.geometry.icon_button, false), .hover_style = S.buttonHover() }).mount(action_scope, cx);
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
        self.tips.clearRetainingCapacity();
        self.selects.clearRetainingCapacity();
        self.buttons.clearRetainingCapacity();
        if (self.render_scope) |old| old.dispose();
        self.render_scope = null;
        while (self.root.children.items.len > 0) {
            const child = self.root.children.items[self.root.children.items.len - 1];
            self.cx.detachChild(self.root, child);
            self.cx.destroyDetached(child);
        }
        self.render_scope = try self.scope.childScope();
        const count = self.controller.model.value.ai.provider_count;
        if (self.controller.ai_fields.new_provider) |index| {
            if (index < count) try self.root.appendChild(self.cx.allocator, try self.providerCard(index));
            const previous = try self.accordion(.existing, 0, 0, "已有 Provider", self.controller.ai_fields.existing_open, 28, true);
            for (0..count) |i| if (i != index) try previous.body.appendChild(self.cx.allocator, try self.providerCard(i));
            try self.root.appendChild(self.cx.allocator, previous.item);
        } else for (0..count) |i| try self.root.appendChild(self.cx.allocator, try self.providerCard(i));
        self.error_node = try ui.textStyled(self.cx, S.errorNote, self.error_text);
        self.error_node.?.meta.ownership.meta.test_id = "settings.ai.provider_error";
        try self.root.appendChild(self.cx.allocator, self.error_node.?);
        self.refresh();
    }
    fn providerCard(self: *ProviderView, i: usize) !*ui.Node {
        const p = self.controller.model.value.ai.providers[i];
        const open = self.controller.ai_fields.provider_open.get(i) orelse (i == 0);
        const result = try self.accordion(.provider, i, 0, draft.providerName(p), open, 30, true);
        result.item.meta.ownership.meta.test_id = try self.id(i, null, "card");
        result.header.style.gap = 6;
        result.title.setDisplay(.none);
        result.chevron.style.width = .{ .px = 14 };
        result.chevron.style.height = .{ .px = 14 };
        if (open) {
            const name_input = try self.input(.{ .provider = i, .field = .name }, "Provider 名称", 244, 30);
            try result.header.appendChild(self.cx.allocator, name_input);
        } else {
            const title = try ui.textStyled(self.cx, S.label, displayName(p));
            title.style.width = .{ .px = 244 };
            title.style.flex_shrink = 1;
            try result.header.appendChild(self.cx.allocator, title);
        }
        try result.header.appendChild(self.cx.allocator, try ui.box(self.cx, .{ .width = .fill(), .flex = 1, .min_width = 0 }, .{}));
        try result.header.appendChild(self.cx.allocator, try ui.iconTint(self.cx, if (p.enabled and draft.eligible(p)) ui.icons.circle_check else ui.icons.circle_slash, S.theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 }));
        const status = try ui.textStyled(self.cx, S.note, "");
        status.style.width = .{ .px = 68 };
        status.style.flex_shrink = 0;
        try self.badges.append(self.scope.allocator, .{ .index = i, .node = status });
        try result.header.appendChild(self.cx.allocator, status);
        const is_default = std.mem.eql(u8, self.controller.model.value.ai.default_provider, draft.providerName(p));
        try result.header.appendChild(self.cx.allocator, try self.iconButton(.default_provider, i, 0, ui.icons.star, if (is_default) "当前默认 Provider" else if (!self.savedEligible(i, null)) "保存有效配置后可设为默认 Provider" else "设为默认 Provider", 28, is_default, is_default or !self.savedEligible(i, null)));
        const connection_open = self.controller.ai_fields.connection_open.get(i) orelse false;
        const connection = try self.accordion(.connection, i, 0, "连接配置", connection_open, 28, true);
        connection.item.meta.ownership.meta.test_id = try self.id(i, null, "connection");
        try connection.header.insertChildBefore(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.plug, S.theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }), connection.title);
        connection.title.style.width = .{ .px = 216 };
        connection.title.style.flex = 0;
        try connection.header.insertChildBefore(self.cx.allocator, try ui.boxStyled(self.cx, S.pluginHeaderSpacer, .{}), connection.chevron);
        const type_row = try row(self.cx, 32);
        try type_row.appendChild(self.cx.allocator, try self.label("协议", 100));
        const kind = try self.selectKind(i, p.kind);
        try type_row.appendChild(self.cx.allocator, kind);
        try connection.body.appendChild(self.cx.allocator, type_row);
        try connection.body.appendChild(self.cx.allocator, try self.connectionField(i, .endpoint, "Endpoint", "https://…"));
        try connection.body.appendChild(self.cx.allocator, try self.connectionField(i, .api_key, "API Key", if (p.kind == .ollama) "可选" else "填写 API Key"));
        const storage = try row(self.cx, 28);
        try storage.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.lock_keyhole, S.theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }));
        try storage.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.note, "API Key 存储于 macOS 钥匙串"));
        try connection.body.appendChild(self.cx.allocator, storage);
        try result.body.appendChild(self.cx.allocator, connection.item);
        for (p.models[0..p.model_count], 0..) |_, j| try result.body.appendChild(self.cx.allocator, try self.modelCard(i, j));
        const actions = try row(self.cx, 28);
        try actions.appendChild(self.cx.allocator, try self.iconButton(.add_model, i, 0, ui.icons.plus, "新增模型", 24, false, false));
        try actions.appendChild(self.cx.allocator, try ui.box(self.cx, .{ .width = .fill(), .flex = 1 }, .{}));
        if (self.controller.ai_fields.new_provider == i) try actions.appendChild(self.cx.allocator, try self.iconButton(.cancel_provider, i, 0, ui.icons.x, "取消新增 Provider", 24, false, false)) else if (i >= 3) try actions.appendChild(self.cx.allocator, try self.iconButton(.delete_provider, i, 0, ui.icons.trash_2, "删除 Provider 前须选择默认替代项", 24, false, is_default)) else try actions.appendChild(self.cx.allocator, try self.tooltipOnly(ui.icons.circle_help, "删除最后或默认模型前，请先选择已有合法的替代项。", 24));
        try result.body.appendChild(self.cx.allocator, actions);
        return result.item;
    }
    fn connectionField(self: *ProviderView, i: usize, field: draft.Field, title: []const u8, placeholder: []const u8) !*ui.Node {
        const r = try row(self.cx, 32);
        r.style.height = .{ .fit = .{} };
        try r.appendChild(self.cx.allocator, try self.label(title, 100));
        try r.appendChild(self.cx.allocator, try self.input(.{ .provider = i, .field = field }, placeholder, 0, 32));
        return r;
    }
    fn modelCard(self: *ProviderView, i: usize, j: usize) !*ui.Node {
        const model = self.controller.model.value.ai.providers[i].models[j];
        const open = self.controller.ai_fields.model_open.get(draft.modelKey(i, j)) orelse false;
        const result = try self.accordion(.model, i, j, if (model.id.len == 0) "新模型" else model.id, open, 32, false);
        result.item.meta.ownership.meta.test_id = try self.id(i, j, "card");
        result.header.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .gap = 6, .align_items = .center, .padding = .{ .left = 8, .right = 8 }, .background = S.theme.current().well, .border = .{ .radius = 7 }, .flex_shrink = 0 });
        result.title.style.width = .{ .px = 216 };
        result.title.style.flex = 0;
        var buffer: [32]u8 = undefined;
        const window = try ui.textStyled(self.cx, S.note, try contextText(model.context_window, &buffer));
        window.style.width = .{ .px = 88 };
        try result.header.appendChild(self.cx.allocator, window);
        try result.header.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.brain, if (model.reasoning) S.theme.current().accent else S.theme.current().fg_3, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } }));
        try result.header.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.image, if (model.vision) S.theme.current().accent else S.theme.current().fg_3, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } }));
        if (!open) try result.header.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.star, if (model.default) S.theme.current().accent else S.theme.current().fg_3, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } }));
        const is_new = if (self.controller.ai_fields.new_model) |new| new.provider == i and new.model == j else false;
        try result.header.appendChild(self.cx.allocator, try self.iconButton(if (is_new) .cancel_model else .delete_model, i, j, if (is_new) ui.icons.x else ui.icons.trash_2, if (is_new) "取消新增模型" else "删除模型前须选择默认替代项", 24, false, !is_new and self.modelProtected(i, j)));
        const headers = try row(self.cx, 16);
        for ([_][]const u8{ "模型 ID", "上下文 · tokens", "推理", "识图", "默认", "" }, [_]f32{ 236, 110, 54, 54, 54, 24 }) |text, width| try headers.appendChild(self.cx.allocator, try self.label(text, width));
        try result.body.appendChild(self.cx.allocator, headers);
        const r = try row(self.cx, 32);
        r.style.height = .{ .fit = .{} };
        try r.appendChild(self.cx.allocator, try self.input(.{ .provider = i, .model = j, .field = .model_id }, "完整模型 ID", 236, 32));
        try r.appendChild(self.cx.allocator, try self.input(.{ .provider = i, .model = j, .field = .context_window }, "正整数", 110, 32));
        const labels = [_][]const u8{ "切换推理能力", "识图能力；保存后用于后续请求，不能替代实际适配器支持", "设为默认模型" };
        const icons = [_]ui.SvgAsset{ ui.icons.brain, ui.icons.image, ui.icons.star };
        const actions = [_]Action{ .reasoning, .vision, .default_model };
        const selected = [_]bool{ model.reasoning, model.vision, model.default };
        for (actions, icons, labels, selected) |action, icon, help, active| {
            const cell = try ui.box(self.cx, .{ .width = .{ .px = 54 }, .height = .{ .px = 32 }, .align_items = .center, .justify = .center, .flex_shrink = 0 }, .{});
            try cell.appendChild(self.cx.allocator, try self.iconButton(action, i, j, icon, help, 32, active, action == .default_model and (active or !self.savedEligible(i, j))));
            try r.appendChild(self.cx.allocator, cell);
        }
        try result.body.appendChild(self.cx.allocator, r);
        const efforts = try row(self.cx, 28);
        try efforts.appendChild(self.cx.allocator, try self.label("effort 能力", 80));
        for ([_][]const u8{ "low", "medium", "high", "xhigh", "max" }, 0..) |name, k| {
            const action_click = try self.click(@fromBackingInt(@intCast(@backingInt(Action.effort0) + k)), i, j);
            var style = S.textButton();
            style.width = .{ .px = 94 };
            style.background = if (model.efforts[k]) S.theme.current().selection else S.theme.current().well;
            style.text_color = if (model.efforts[k]) S.theme.current().accent else S.theme.current().fg_2;
            const button = try ui.widgets.Button(.{ .label = name, .a11y_label = name, .disabled = self.disabled, .on_click = self.cx.on(Click, action_click, Click.run), .base_style = style, .hover_style = S.buttonHover() }).mount(self.render_scope.?, self.cx);
            button.meta.ownership.meta.test_id = try self.id(i, j, name);
            if (button.behavior.interaction.a11y) |*a| {
                a.role = .checkbox;
                a.checked = model.efforts[k];
            }
            try efforts.appendChild(self.cx.allocator, button);
        }
        try result.body.appendChild(self.cx.allocator, efforts);
        return result.item;
    }
    fn savedEligible(self: *ProviderView, i: usize, j: ?usize) bool {
        const saved = self.controller.original.value.ai;
        const current = self.controller.model.value.ai;
        if (j == null and i < current.provider_count and current.providers[i].enabled and draft.eligible(current.providers[i])) {
            var has_saved_default = false;
            for (saved.providers[0..saved.provider_count]) |provider| if (provider.enabled and draft.eligible(provider) and std.mem.eql(u8, draft.providerName(provider), saved.default_provider)) {
                has_saved_default = true;
            };
            // Initial configuration needs an explicit default before its first Save.
            if (!has_saved_default) return true;
        }
        if (i >= saved.provider_count or i >= current.provider_count or !saved.providers[i].enabled or !draft.eligible(saved.providers[i]) or !current.providers[i].enabled or !draft.eligible(current.providers[i])) return false;
        if (j) |index| return index < saved.providers[i].model_count and index < current.providers[i].model_count and std.mem.eql(u8, saved.providers[i].models[index].id, current.providers[i].models[index].id);
        return true;
    }
    fn modelProtected(self: *ProviderView, i: usize, j: usize) bool {
        const p = self.controller.model.value.ai.providers[i];
        return p.model_count <= 1 or p.models[j].default;
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
        const select = try ui.widgets.Select(.{ .value = ui.split(value, self.cx.on(Click, action_click, Click.kind)), .width = @as(f32, 454), .disabled = self.disabled, .options = &[_]ui.widgets.SelectOption{ .{ .value = "anthropic", .label = "Anthropic Messages" }, .{ .value = "openai_compat", .label = "OpenAI 兼容" }, .{ .value = "ollama", .label = "Ollama" } } }).mount(self.render_scope.?, self.cx);
        select.trigger.setStyleInline(self.cx.allocator, S.providerInput(0, 32));
        select.wrapper.style.width = .fill();
        select.wrapper.style.flex = 1;
        select.trigger.meta.ownership.meta.test_id = try self.id(i, null, "kind");
        S.tuneSelect(select);
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
        const button = try ui.widgets.Button(.{ .icon_asset = icon, .icon_only = true, .icon_size = @as(f32, 16), .a11y_label = help, .disabled = disabled, .on_click = self.cx.on(Click, action_click, Click.run), .base_style = style, .hover_style = S.buttonHover() }).mount(scope, self.cx);
        button.meta.ownership.meta.test_id = try self.id(i, switch (action) {
            .reasoning, .vision, .default_model, .delete_model, .cancel_model => j,
            else => null,
        }, @tagName(action));
        try tip.trigger.appendChild(self.cx.allocator, button);
        try self.bindTipFocus(button, tip.open.?);
        return tip.wrapper;
    }
    fn tooltipOnly(self: *ProviderView, icon: ui.SvgAsset, help: []const u8, size: f32) !*ui.Node {
        const tip = try self.tooltip(help);
        const button = try ui.widgets.Button(.{ .icon_asset = icon, .icon_only = true, .icon_size = @as(f32, 16), .a11y_label = help, .base_style = S.button(size, false), .hover_style = S.buttonHover() }).mount(self.render_scope.?, self.cx);
        try tip.trigger.appendChild(self.cx.allocator, button);
        try self.bindTipFocus(button, tip.open.?);
        return tip.wrapper;
    }
    fn tooltip(self: *ProviderView, text: []const u8) !ui.widgets.TooltipResult {
        const open = try self.render_scope.?.createSignal(bool, false);
        const tip = try ui.widgets.Tooltip(.{ .text = text, .open = open, .position = .top, .open_delay_ms = 450, .background = S.theme.current().overlay, .text_color = S.theme.current().fg_1, .font_size = 10.5 }).mount(self.render_scope.?, self.cx);
        tip.content.setStyleInline(self.cx.allocator, S.fieldHelp(undefined));
        for (tip.content.children.items) |tip_label| if (tip_label.getText()) |old| {
            var props = old;
            props.wrap = .word;
            props.line_height = 16.0 / 10.5;
            tip_label.setText(props);
            tip_label.style.width = .fill();
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
            .default_provider => self.provider >= ai.provider_count or std.mem.eql(u8, ai.default_provider, draft.providerName(ai.providers[self.provider])) or !self.view.savedEligible(self.provider, null),
            .default_model => self.provider >= ai.provider_count or self.model >= ai.providers[self.provider].model_count or ai.providers[self.provider].models[self.model].default or !self.view.savedEligible(self.provider, self.model),
            .delete_model => self.provider >= ai.provider_count or self.view.modelProtected(self.provider, self.model),
            .delete_provider => self.provider >= ai.provider_count or std.mem.eql(u8, ai.default_provider, draft.providerName(ai.providers[self.provider])),
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
const Action = enum { add_provider, cancel_provider, delete_provider, add_model, cancel_model, delete_model, default_provider, default_model, reasoning, vision, effort0, effort1, effort2, effort3, effort4, kind };
const Click = struct {
    view: *ProviderView,
    action: Action,
    provider: usize,
    model: usize,
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
        p.enabled = draft.eligible(p.*);
        self.view.controller.editProviders(owned.value.ai) catch return;
        self.view.schedule();
    }
    fn run(self: *Click) void {
        const v = self.view;
        if (v.disabled.peek()) return;
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
                if (self.action == .delete_provider and std.mem.eql(u8, ai.default_provider, draft.providerName(ai.providers[self.provider]))) {
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
                        p.enabled = draft.eligible(p.*);
                        v.controller.editProviders(ai.*) catch return;
                        v.controller.ai_fields.removeModel(v.scope.allocator, self.provider, self.model);
                        v.controller.refreshDirty();
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
                        p.enabled = draft.eligible(p.*);
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
fn displayName(p: config.AiProvider) []const u8 {
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
    if (value >= 1_000_000) return std.fmt.bufPrint(buffer, "{d:.1}M tokens", .{@as(f64, @floatFromInt(value)) / 1_000_000});
    if (value >= 1000) return std.fmt.bufPrint(buffer, "{d:.0}K tokens", .{@as(f64, @floatFromInt(value)) / 1000});
    return std.fmt.bufPrint(buffer, "{d} tokens", .{value});
}
