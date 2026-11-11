//! Native settings forms; imports and connection tests use owned, isolated jobs.
const std = @import("std");
const ui = @import("ui");
const ext = @import("ai_extensions.zig");
const Controller = @import("settings_controller.zig").Controller;
const S = @import("settings_styles.zig");
const M = @import("settings_mcp_styles.zig");
const controls = @import("settings_parts/settings_controls.zig");
const local = @import("../ai/local_skills.zig");
const mcp = @import("../ai/mcp_client.zig");
const oauth = @import("../ai/mcp_oauth.zig");
const Cancel = @import("../ai/provider.zig").CancelToken;
pub const Hooks = struct { context: *anyopaque, changed: *const fn (*anyopaque) void };
const Field = enum { name, program, arguments, cwd, environment, endpoint, headers, timeout, bindings, roots, oauth_client_id, oauth_scope };
const Action = enum { choose_skill, cancel_job, toggle_skill, reimport, view_skill, view_server, remove_skill, new_server, edit_server, toggle_server, remove_server, test_server, authorize_server, logout_server, apply, cancel_editor, stdio, http, clear_environment, clear_headers };
extern "c" fn zw_pick_skill_path([*]u8, c_int) c_int;
pub const View = struct {
    root: *ui.Node,
    scope: *ui.Scope,
    render_scope: ?*ui.Scope = null,
    cx: *ui.Cx,
    controller: *Controller,
    hooks: Hooks,
    data_root: []const u8,
    job: ?*Job = null,
    pending: bool = false,
    status: []const u8 = "",
    status_error: bool = false,
    status_area: enum { skills, mcp } = .skills,
    detail: []const u8 = "",
    detail_open: bool = false,
    detail_target: ?union(enum) {
        skill: struct { id: []const u8, revision: []const u8 },
        server: struct { id: []const u8, revision: u64 },
    } = null,
    test_results: [16]?struct { id: []const u8, revision: u64, label: []const u8, detail: []const u8 = "", failed: bool = false } = @splat(null),
    form_values: [@typeInfo(Field).@"enum".field_names.len]?[]const u8 = @splat(null),
    editing: bool = false,
    edit_index: ?usize = null,
    transport: @FieldType(ext.Server, "transport") = .stdio,
    fields: [@typeInfo(Field).@"enum".field_names.len]?*ui.Signal([]const u8) = @splat(null),
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, controller: *Controller, root: []const u8, hooks: Hooks) !*View {
        const self = try scope.allocator.create(View);
        self.* = .{ .root = try ui.boxStyled(cx, S.sectionColumn, .{}), .scope = scope, .cx = cx, .controller = controller, .hooks = hooks, .data_root = try controls.owned(scope, root) };
        self.root.meta.ownership.meta.test_id = "settings.ai.extensions";
        try scope.onCleanup(View, self, cleanup);
        try self.rebuild();
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.job) |job| {
            job.cancel.cancel();
            job.thread.?.join();
            job.destroy();
        }
        self.scope.allocator.destroy(self);
    }
    pub fn busy(self: *const View) bool {
        return self.job != null;
    }
    pub fn hasEditor(self: *const View) bool {
        return self.editing;
    }
    fn notify(self: *View) void {
        self.hooks.changed(self.hooks.context);
        self.cx.requestRedraw();
    }
    fn message(self: *View, content: []const u8) void {
        self.status_error = false;
        self.status = controls.owned(self.scope, content) catch "操作失败";
        self.pending = true;
        self.notify();
    }
    fn failure(self: *View, err: anyerror) void {
        self.message(errorMessage(err));
        self.status_error = true;
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.job) |job| {
            if (job.done.load(.acquire)) {
                job.thread.?.join();
                self.job = null;
                defer job.destroy();
                self.status_area = if (job.mcpJob()) .mcp else .skills;
                if (job.mcpJob() and job.draft_id == self.controller.draft_id) {
                    const i = job.index.?;
                    const server = job.frozen.servers[i];
                    const label = if (job.problem) |err| tryLabel: {
                        break :tryLabel if (job.output.len != 0) job.output else errorMessage(err);
                    } else job.summary;
                    self.test_results[i] = .{ .id = controls.owned(self.scope, server.id) catch "", .revision = server.revision, .label = controls.owned(self.scope, label) catch "测试结果无法保留", .detail = if (job.problem == null) controls.owned(self.scope, job.output) catch "" else "", .failed = job.problem != null };
                }
                if (job.draft_id != self.controller.draft_id or self.controller.state() == .saving) {
                    self.message("设置草稿已变化，本次结果已丢弃。");
                    self.status_error = true;
                } else if (job.problem) |err| {
                    if (job.output.len != 0) self.message(job.output) else self.failure(err);
                    self.status_error = true;
                    self.status_area = if (job.mcpJob()) .mcp else .skills;
                } else {
                    if (job.imported.items.len != 0) {
                        var extensions = self.controller.model.value.ai.extensions;
                        var list: std.ArrayList(ext.Skill) = .empty;
                        defer list.deinit(self.scope.allocator);
                        list.appendSlice(self.scope.allocator, extensions.skills) catch return .done;
                        if (job.index) |i| {
                            if (i >= list.items.len or !std.mem.eql(u8, list.items[i].id, job.frozen.skills[i].id)) {
                                self.message("技能选择已变化，请重新导入。");
                                self.status_error = true;
                                return .needs_layout;
                            }
                            list.items[i] = job.imported.items[0].skill;
                        } else for (job.imported.items) |imported| list.append(self.scope.allocator, imported.skill) catch return .done;
                        extensions.skills = list.items;
                        self.controller.setExtensions(extensions) catch |err| {
                            self.failure(err);
                            return .needs_layout;
                        };
                    } else if (job.kind == .read) {
                        self.detail = controls.owned(self.scope, job.output) catch "";
                        const skill = job.frozen.skills[job.index.?];
                        self.detail_target = .{ .skill = .{ .id = controls.owned(self.scope, skill.id) catch "", .revision = controls.owned(self.scope, skill.revision) catch "" } };
                        self.detail_open = true;
                    }
                }
                self.pending = true;
            } else {
                if (job.browser_pending.swap(false, .acq_rel)) {
                    const Native = struct {
                        extern fn macos_open_url([*:0]const u8) c_int;
                    };
                    const url = job.arena.allocator().dupeSentinel(u8, job.browser_url, 0) catch {
                        job.browser_result.store(-1, .release);
                        return .needs_layout;
                    };
                    job.browser_result.store(if (Native.macos_open_url(url) == 1) 1 else -1, .release);
                }
                self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
            }
        }
        if (!self.pending) return .done;
        self.pending = false;
        self.rebuild() catch |err| {
            self.status = @errorName(err);
            return .done;
        };
        return .needs_layout;
    }
    fn text(self: *View, parent: *ui.Node, content: []const u8, title: bool) !void {
        const owned = try controls.owned(self.render_scope.?, content);
        const node = if (title) try ui.textStyled(self.cx, S.title, owned) else try ui.textStyled(self.cx, S.sectionSummary, owned);
        node.style.width = .fill();
        node.setStyleInline(self.cx.allocator, .{ .min_width = 0 });
        try parent.appendChild(self.cx.allocator, node);
    }
    fn statusText(self: *View, parent: *ui.Node) !void {
        if (!self.status_error or self.status.len == 0) return;
        const content = try controls.owned(self.render_scope.?, self.status);
        const node = try ui.textStyled(self.cx, S.errorNote, content);
        node.style.width = .fill();
        node.setStyleInline(self.cx.allocator, .{ .min_width = 0 });
        node.meta.ownership.meta.test_id = "settings.extensions.status";
        try parent.appendChild(self.cx.allocator, node);
    }
    fn card(self: *View, title: []const u8, hint: []const u8, id: []const u8, icon: ui.SvgAsset, bit: u6) !*ui.Node {
        const scope = self.render_scope.?;
        const fold = try scope.createState(Fold, .{ .view = self, .bit = bit });
        const expanded = self.controller.search_query.len != 0 or self.controller.folded_sections & (@as(u64, 1) << bit) == 0;
        const result = try @import("settings_accordion.zig").item(.{ .title = title, .expanded = expanded, .on_change = self.cx.on(Fold, fold, Fold.change), .variant = .ghost }).mount(scope, self.cx);
        const is_mcp = std.mem.eql(u8, id, "settings.ai.mcp");
        _ = try controls.sectionHeader(self.cx, scope, result, icon, expanded, if (is_mcp) "" else hint, id);
        if (is_mcp and !self.editing) {
            result.header.removeChild(result.chevron);
            const space = try ui.box(self.cx, .{ .width = .{ .px = 86 }, .height = .{ .px = 28 }, .flex_shrink = 0 }, .{});
            try result.header.appendChild(self.cx.allocator, space);
            try result.header.appendChild(self.cx.allocator, result.chevron);
            const state = try scope.createState(Button, .{ .view = self, .action = .new_server, .index = 0 });
            const add = try ui.widgets.Button(.{ .label = "添加", .a11y_label = "添加 MCP 服务", .icon_asset = ui.icons.plus, .icon_size = @as(f32, 14), .variant = .ghost, .disabled = self.job != null or self.controller.state() == .saving, .base_style = M.testAction(), .on_click = self.cx.on(Button, state, Button.click) }).mount(scope, self.cx);
            add.setStyleInline(self.cx.allocator, .{ .position = .absolute, .inset = .{ .right = .{ .px = 34 }, .top = .{ .px = 12 } } });
            add.meta.ownership.meta.test_id = "settings.mcp.add";
            try result.item.appendChild(self.cx.allocator, add);
        }
        result.item.meta.ownership.meta.test_id = id;
        result.header.meta.ownership.meta.test_id = try controls.stableId(scope, id, ".header");
        if (self.controller.state() == .saving or self.controller.search_query.len != 0) {
            result.header.behavior.events.on_event = null;
            result.header.setFocusable(false);
        }
        result.body.setStyleInline(self.cx.allocator, S.column(undefined));
        result.body.setStyleInline(self.cx.allocator, .{ .padding = .{ .left = 16, .right = 16, .bottom = 8 }, .gap = 10 });
        try self.root.appendChild(self.cx.allocator, result.item);
        if (!std.mem.eql(u8, id, "settings.ai.mcp") and !std.mem.eql(u8, id, "settings.ai.skills")) try self.text(result.body, hint, false);
        return result.body;
    }
    const Fold = struct {
        view: *View,
        bit: u6,
        fn change(self: *@This(), open: bool) void {
            if (self.view.controller.state() == .saving or self.view.controller.search_query.len != 0) return;
            const mask = @as(u64, 1) << self.bit;
            if (open) self.view.controller.folded_sections &= ~mask else self.view.controller.folded_sections |= mask;
            self.view.cx.requestRedraw();
        }
    };
    fn row(self: *View, parent: *ui.Node) !*ui.Node {
        const node = try ui.box(self.cx, .{ .direction = .row, .gap = 6, .width = .fill(), .min_width = 0, .align_items = .center }, .{});
        try parent.appendChild(self.cx.allocator, node);
        return node;
    }
    fn button(self: *View, parent: *ui.Node, label: []const u8, action: Action, index: usize, id: []const u8) !void {
        const scope = self.render_scope.?;
        const state = try scope.createState(Button, .{ .view = self, .action = action, .index = index });
        const node = try ui.widgets.Button(.{ .label = label, .variant = .secondary, .on_click = self.cx.on(Button, state, Button.click) }).mount(scope, self.cx);
        node.setStyleInline(self.cx.allocator, S.fieldButton());
        node.setStyleInline(self.cx.allocator, .{ .width = .{ .fit = .{} }, .flex = 0, .flex_shrink = 0 });
        node.meta.ownership.meta.test_id = try controls.owned(scope, id);
        try parent.appendChild(self.cx.allocator, node);
    }
    fn input(self: *View, parent: *ui.Node, label: []const u8, initial: []const u8, id: []const u8, secret: bool, multiline: bool) !*ui.Signal([]const u8) {
        const scope = self.render_scope.?;
        const field = try ui.boxStyled(self.cx, S.column, .{});
        field.style.gap = 4;
        field.style.width = .fill();
        try self.text(field, label, false);
        const value = try scope.createText(initial, .{});
        if (multiline) {
            const result = try ui.widgets.Textarea(.{ .value = value, .rows = @as(u32, 2) }).mountResult(scope, self.cx);
            result.wrapper.meta.ownership.meta.test_id = id;
            try field.appendChild(self.cx.allocator, result.wrapper);
        } else {
            var result = try ui.widgets.Input(.{ .value = value, .input_type = @as(ui.widgets.InputType, if (secret) .password else .text) }).mountResult(scope, self.cx);
            @import("../ui/app_theme.zig").styleInput(result);
            result.input_container.setStyleInline(self.cx.allocator, S.providerInput(0, 32));
            result.node.style.width = .fill();
            S.tuneInput(&result);
            result.input_container.meta.ownership.meta.test_id = id;
            result.input_container.behavior.interaction.a11y = .{ .role = .textbox, .label = label };
            try field.appendChild(self.cx.allocator, result.node);
        }
        try parent.appendChild(self.cx.allocator, field);
        return value;
    }
    fn rebuild(self: *View) !void {
        for (self.fields, 0..) |maybe, i| if (maybe) |signal| {
            self.form_values[i] = try controls.owned(self.scope, signal.peek());
        };
        if (self.render_scope) |old| {
            if (self.cx.focus_manager.current_focus) |focused| if (focused.isDescendantOf(self.root)) self.cx.clearFocus();
            old.dispose();
            while (self.root.children.items.len > 0) {
                const child = self.root.children.items[self.root.children.items.len - 1];
                self.cx.detachChild(self.root, child);
                self.cx.destroyDetached(child);
            }
        }
        self.render_scope = try self.scope.childScope();
        self.fields = @splat(null);
        const skills_card = try self.card("本地技能", "导入 SKILL.md 或技能文件夹，保存后供助手使用。", "settings.ai.skills", ui.icons.sparkles, 31);
        skills_card.meta.ownership.meta.test_id = "settings.skills.drop";
        skills_card.behavior.events.on_event = dropEvent;
        skills_card.behavior.events.event_context = self;
        const toolbar = try ui.boxStyled(self.cx, M.skillsToolbar, .{});
        toolbar.meta.ownership.meta.test_id = "settings.skills.toolbar";
        const skills = self.controller.model.value.ai.extensions.skills;
        var enabled: usize = 0;
        for (skills) |skill| if (skill.enabled) {
            enabled += 1;
        };
        const summary = try ui.textStyled(self.cx, M.metadata, try std.fmt.allocPrint(self.render_scope.?.allocator, "{d} 个技能 · {d} 个启用", .{ skills.len, enabled }));
        summary.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .flex = 1 });
        summary.meta.ownership.meta.test_id = "settings.skills.summary";
        try toolbar.appendChild(self.cx.allocator, summary);
        try self.compactButton(toolbar, "添加技能", .choose_skill, 0, "settings.skills.add");
        try skills_card.appendChild(self.cx.allocator, toolbar);
        for (self.controller.model.value.ai.extensions.skills, 0..) |skill, i| try self.skillRow(skills_card, skill, i);
        if (self.status_area == .skills) try self.statusText(skills_card);
        const mcp_card = try self.card("MCP 服务", "连接外部工具与资源，供助手在对话中使用。", "settings.ai.mcp", ui.icons.plug, 32);
        for (self.controller.model.value.ai.extensions.servers, 0..) |server, i| try self.serverRow(mcp_card, server, i);
        if (self.editing) try self.form(mcp_card);
        if (self.job != null) {
            try self.text(self.root, "正在处理…", false);
            try self.button(self.root, "取消", .cancel_job, 0, "settings.extensions.cancel");
        }
        if (self.status_area == .mcp) try self.statusText(mcp_card);
    }
    fn skillExpanded(self: *const View, skill: ext.Skill) bool {
        if (!self.detail_open) return false;
        return if (self.detail_target) |target| switch (target) {
            .skill => |owner| std.mem.eql(u8, owner.id, skill.id) and std.mem.eql(u8, owner.revision, skill.revision),
            else => false,
        } else false;
    }
    fn serverExpanded(self: *const View, server: ext.Server) bool {
        if (!self.detail_open) return false;
        return if (self.detail_target) |target| switch (target) {
            .server => |owner| std.mem.eql(u8, owner.id, server.id) and owner.revision == server.revision,
            else => false,
        } else false;
    }
    fn preview(self: *View, parent: *ui.Node) !void {
        if (self.detail.len == 0) return;
        const value = try self.render_scope.?.createText(self.detail, .{});
        const node = try ui.widgets.Textarea(.{ .value = value, .rows = @as(u32, 6), .readonly = true }).mount(self.render_scope.?, self.cx);
        node.meta.ownership.meta.test_id = "settings.extensions.detail";
        try parent.appendChild(self.cx.allocator, node);
    }
    fn compactButton(self: *View, parent: *ui.Node, label: []const u8, action: Action, index: usize, id: []const u8) !void {
        const scope = self.render_scope.?;
        const state = try scope.createState(Button, .{ .view = self, .action = action, .index = index });
        const node = try ui.widgets.Button(.{ .label = label, .variant = .ghost, .disabled = self.job != null or self.controller.state() == .saving, .base_style = M.testAction(), .on_click = self.cx.on(Button, state, Button.click) }).mount(scope, self.cx);
        node.meta.ownership.meta.test_id = try controls.owned(scope, id);
        if (action == .view_skill) if (node.behavior.interaction.a11y) |*access| {
            access.expanded = self.skillExpanded(self.controller.model.value.ai.extensions.skills[index]);
        };
        try parent.appendChild(self.cx.allocator, node);
    }
    fn skillRow(self: *View, parent: *ui.Node, skill: ext.Skill, index: usize) !void {
        const scope = self.render_scope.?;
        const a = scope.allocator;
        const busy_now = self.job != null or self.controller.state() == .saving;
        const node = try ui.boxStyled(self.cx, M.service, .{});
        node.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "settings.skill.{d}.row", .{index});
        const top = try self.row(node);
        top.setStyleInline(self.cx.allocator, .{ .gap = 10 });
        const icon = try ui.box(self.cx, .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .align_items = .center, .justify = .center, .background = S.theme.current().selection, .border = .{ .radius = 14 }, .flex_shrink = 0 }, .{});
        try icon.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.sparkles, S.theme.current().accent_ink, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }));
        try top.appendChild(self.cx.allocator, icon);
        const identity = try ui.boxStyled(self.cx, M.identity, .{});
        const tip = try ui.widgets.Tooltip(.{ .text = skill.name, .open_delay_ms = 450 }).mount(scope, self.cx);
        tip.wrapper.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 18 }, .min_width = 0, .overflow_hidden = true });
        tip.trigger.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 18 }, .min_width = 0 });
        const title = try ui.textStyled(self.cx, M.title, try controls.owned(scope, skill.name));
        title.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 18 }, .flex = 1, .min_width = 0, .overflow_hidden = true });
        title.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "settings.skill.{d}.name", .{index});
        try tip.trigger.appendChild(self.cx.allocator, title);
        try identity.appendChild(self.cx.allocator, tip.wrapper);
        const description = try ui.textStyled(self.cx, M.metadata, try controls.owned(scope, skill.description));
        description.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .overflow_hidden = true });
        description.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "settings.skill.{d}.description", .{index});
        try identity.appendChild(self.cx.allocator, description);
        try top.appendChild(self.cx.allocator, identity);
        const state = try scope.createState(Button, .{ .view = self, .action = .toggle_skill, .index = index });
        const checked = try scope.createSignal(bool, skill.enabled);
        const toggle = try ui.widgets.Switch(.{ .checked = checked, .disabled = busy_now, .on_change = self.cx.on(Button, state, Button.toggle) }).mount(scope, self.cx);
        toggle.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "settings.skill.{d}.toggle", .{index});
        if (toggle.behavior.interaction.a11y) |*access| access.label = try std.fmt.allocPrint(a, "{s}{s}", .{ if (skill.enabled) "停用 " else "启用 ", skill.name });
        try scope.createEffect(.{ .cx = self.cx, .node = toggle, .checked = checked }, struct {
            fn run(args: anytype) void {
                S.paintSwitch(args.cx, args.node, args.checked.get());
            }
        }.run);
        try top.appendChild(self.cx.allocator, toggle);
        try self.compactButton(top, if (self.skillExpanded(skill)) "收起" else "查看", .view_skill, index, try std.fmt.allocPrint(a, "settings.skill.{d}.view", .{index}));
        const items = [_]ui.widgets.MenuItem{ try self.menuItem(index, "重新导入", .reimport, ui.icons.refresh_cw, false), .{ .kind = .separator }, try self.menuItem(index, "移除", .remove_skill, ui.icons.trash, true) };
        const open = try scope.createSignal(bool, false);
        const menu = try ui.widgets.Menu(.{ .trigger = .manual, .open = open, .items = &items, .width = @as(f32, 180), .position = .bottom_end }).mount(scope, self.cx);
        menu.wrapper.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .flex_shrink = 0 });
        const more = try scope.createState(More, .{ .open = open });
        const button_node = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.ellipsis, .icon_size = @as(f32, 16), .a11y_label = "更多技能操作", .disabled = busy_now, .variant = .ghost, .base_style = M.moreAction(), .on_click = self.cx.on(More, more, More.click) }).mount(scope, self.cx);
        button_node.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "settings.skill.{d}.more", .{index});
        if (button_node.behavior.interaction.a11y) |*access| access.has_popup = .menu;
        try menu.trigger.appendChild(self.cx.allocator, button_node);
        try top.appendChild(self.cx.allocator, menu.wrapper);
        if (self.skillExpanded(skill)) try self.preview(node);
        try parent.appendChild(self.cx.allocator, node);
    }
    fn serverRow(self: *View, parent: *ui.Node, server: ext.Server, index: usize) !void {
        const scope = self.render_scope.?;
        const a = scope.allocator;
        const busy_now = self.job != null or self.controller.state() == .saving;
        const card_node = try ui.boxStyled(self.cx, M.service, .{});
        card_node.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "settings.mcp.{d}.row", .{index});
        const top = try self.row(card_node);
        top.setStyleInline(self.cx.allocator, .{ .gap = 10 });
        const icon = try ui.box(self.cx, .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .justify = .center, .background = S.theme.current().selection, .border = .{ .radius = 14 }, .flex_shrink = 0 }, .{});
        try icon.appendChild(self.cx.allocator, try ui.iconTint(self.cx, if (server.transport == .stdio) ui.icons.server else ui.icons.globe, S.theme.current().accent_ink, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }));
        try top.appendChild(self.cx.allocator, icon);
        const identity = try ui.boxStyled(self.cx, M.identity, .{});
        const tip = try ui.widgets.Tooltip(.{ .text = server.name, .open_delay_ms = 450 }).mount(scope, self.cx);
        tip.wrapper.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 18 }, .min_width = 0, .overflow_hidden = true });
        tip.trigger.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 18 }, .min_width = 0 });
        const title = try ui.textStyled(self.cx, M.title, try controls.owned(scope, server.name));
        title.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "settings.mcp.{d}.name", .{index});
        title.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 18 }, .flex = 1, .min_width = 0, .overflow_hidden = true });
        try tip.trigger.appendChild(self.cx.allocator, title);
        try identity.appendChild(self.cx.allocator, tip.wrapper);
        const tested = if (self.test_results[index]) |value| std.mem.eql(u8, value.id, server.id) and value.revision == server.revision else false;
        const address = if (server.transport == .stdio) try std.fmt.allocPrint(a, "本地 · {s}", .{std.fs.path.basename(server.program)}) else server.endpoint[0 .. std.mem.indexOfScalar(u8, server.endpoint, '?') orelse server.endpoint.len];
        const metadata = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ address, if (tested and self.test_results[index].?.failed) "" else " · ", if (tested and self.test_results[index].?.failed) "" else if (tested) self.test_results[index].?.label else "未测试" });
        const meta = try ui.textStyled(self.cx, M.metadata, metadata);
        meta.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "settings.mcp.{d}.metadata", .{index});
        meta.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .overflow_hidden = true });
        try identity.appendChild(self.cx.allocator, meta);
        try top.appendChild(self.cx.allocator, identity);
        const state = try scope.createState(Button, .{ .view = self, .action = .toggle_server, .index = index });
        const checked = try scope.createSignal(bool, server.enabled);
        const toggle = try ui.widgets.Switch(.{ .checked = checked, .disabled = busy_now, .on_change = self.cx.on(Button, state, Button.toggle) }).mount(scope, self.cx);
        toggle.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "settings.mcp.{d}.toggle", .{index});
        if (toggle.behavior.interaction.a11y) |*access| access.label = try std.fmt.allocPrint(a, "{s}{s}", .{ if (server.enabled) "停用 " else "启用 ", server.name });
        try scope.createEffect(.{ .cx = self.cx, .node = toggle, .checked = checked }, struct {
            fn run(args: anytype) void {
                S.paintSwitch(args.cx, args.node, args.checked.get());
            }
        }.run);
        try top.appendChild(self.cx.allocator, toggle);
        const test_state = try scope.createState(Button, .{ .view = self, .action = .test_server, .index = index });
        const test_button = try ui.widgets.Button(.{ .label = "测试", .a11y_label = "测试连接", .disabled = busy_now, .variant = .ghost, .base_style = M.testAction(), .on_click = self.cx.on(Button, test_state, Button.click) }).mount(scope, self.cx);
        test_button.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "settings.mcp.{d}.test", .{index});
        try top.appendChild(self.cx.allocator, test_button);
        const view_state = try scope.createState(Button, .{ .view = self, .action = .view_server, .index = index });
        const view_button = try ui.widgets.Button(.{ .label = if (self.serverExpanded(server)) "收起" else "查看", .a11y_label = if (self.serverExpanded(server)) "收起工具详情" else "查看工具详情", .disabled = busy_now or !tested or self.test_results[index].?.failed, .variant = .ghost, .base_style = M.testAction(), .on_click = self.cx.on(Button, view_state, Button.click) }).mount(scope, self.cx);
        view_button.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "settings.mcp.{d}.view", .{index});
        if (view_button.behavior.interaction.a11y) |*access| access.expanded = self.serverExpanded(server);
        try top.appendChild(self.cx.allocator, view_button);
        var items: std.ArrayList(ui.widgets.MenuItem) = .empty;
        try items.append(a, try self.menuItem(index, "编辑", .edit_server, ui.icons.pencil, false));
        if (server.transport == .http) {
            try items.append(a, try self.menuItem(index, "网页登录", .authorize_server, ui.icons.external_link, false));
            if (oauth.authorized(server)) try items.append(a, try self.menuItem(index, "退出授权", .logout_server, ui.icons.log_out, false));
        }
        try items.append(a, .{ .kind = .separator });
        try items.append(a, try self.menuItem(index, "移除", .remove_server, ui.icons.trash, true));
        const open = try scope.createSignal(bool, false);
        const menu = try ui.widgets.Menu(.{ .trigger = .manual, .open = open, .items = items.items, .width = @as(f32, 180), .position = .bottom_end }).mount(scope, self.cx);
        menu.wrapper.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .flex_shrink = 0 });
        const more = try scope.createState(More, .{ .open = open });
        const more_button = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.ellipsis, .icon_size = @as(f32, 16), .a11y_label = "更多服务操作", .disabled = busy_now, .variant = .ghost, .base_style = M.moreAction(), .on_click = self.cx.on(More, more, More.click) }).mount(scope, self.cx);
        more_button.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "settings.mcp.{d}.more", .{index});
        if (more_button.behavior.interaction.a11y) |*access| access.has_popup = .menu;
        try menu.trigger.appendChild(self.cx.allocator, more_button);
        try top.appendChild(self.cx.allocator, menu.wrapper);
        if (tested and self.test_results[index].?.failed) {
            const note = try ui.textStyled(self.cx, S.errorNote, try controls.owned(scope, self.test_results[index].?.label));
            note.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .margin = .{ .left = 38 } });
            try card_node.appendChild(self.cx.allocator, note);
        }
        if (self.serverExpanded(server)) try self.preview(card_node);
        try parent.appendChild(self.cx.allocator, card_node);
    }
    const More = struct {
        open: *ui.Signal(bool),
        fn click(self: *@This()) void {
            self.open.set(!self.open.peek());
        }
    };
    fn menuItem(self: *View, index: usize, label: []const u8, action: Action, icon: ui.SvgAsset, danger: bool) !ui.widgets.MenuItem {
        const scope = self.render_scope.?;
        const state = try scope.createState(Button, .{ .view = self, .action = action, .index = index });
        return .{ .id = @tagName(action), .label = label, .icon_asset = icon, .danger = danger, .disabled = self.job != null or self.controller.state() == .saving, .on_click = self.cx.on(Button, state, Button.click) };
    }
    fn form(self: *View, parent: *ui.Node) !void {
        const server: ?ext.Server = if (self.edit_index) |i| self.controller.model.value.ai.extensions.servers[i] else null;
        const switching = try self.row(parent);
        try self.button(switching, if (self.transport == .stdio) "stdio ✓" else "stdio", .stdio, 0, "settings.mcp.stdio");
        try self.button(switching, if (self.transport == .http) "HTTP ✓" else "HTTP", .http, 0, "settings.mcp.http");
        inline for (@typeInfo(Field).@"enum".field_names) |field_name| {
            const key: Field = @field(Field, field_name);
            const field_index = @backingInt(key);
            const visible = switch (key) {
                .program, .arguments, .cwd, .environment => self.transport == .stdio,
                .endpoint, .headers, .oauth_client_id, .oauth_scope => self.transport == .http,
                else => true,
            };
            if (visible) {
                const initial = if (self.form_values[field_index]) |saved| try self.render_scope.?.allocator.dupe(u8, saved) else try fieldValue(self.render_scope.?.allocator, server, key);
                defer self.render_scope.?.allocator.free(initial);
                const label = switch (key) {
                    .name => "服务名称",
                    .program => "程序绝对路径",
                    .arguments => "参数 · 每行一个，不解析引号和 shell",
                    .cwd => "工作目录 · 留空使用应用工作目录",
                    .environment => "环境变量 · 每行 NAME=value；作为秘密保存；留空保留原值",
                    .endpoint => "HTTP 地址 · HTTPS 或本机 HTTP",
                    .headers => "请求头 · 每行 Name:value；作为秘密保存；留空保留原值",
                    .timeout => "超时（毫秒，100–120000）",
                    .bindings => "允许助手调用的工具 · 每行一个工具名",
                    .roots => "共享根目录 · 每行一个 file:/// URI；留空不共享",
                    .oauth_client_id => "OAuth Client ID · 可留空自动注册",
                    .oauth_scope => "OAuth Scope · 留空使用服务声明",
                };
                self.fields[field_index] = try self.input(parent, label, initial, "settings.mcp.field." ++ field_name, key == .environment or key == .headers, key == .arguments or key == .bindings or key == .environment or key == .headers or key == .roots);
            }
        }
        try self.text(parent, "新服务默认停用。先应用到草稿，可测试连接，再启用并保存。应用前请勿离开本页。", false);
        const actions = try self.row(parent);
        try self.button(actions, "应用到草稿", .apply, 0, "settings.mcp.apply");
        try self.button(actions, "取消编辑", .cancel_editor, 0, "settings.mcp.cancel");
        if (server != null) {
            const clear = try self.row(parent);
            try self.button(clear, "清除环境变量", .clear_environment, 0, "settings.mcp.clear_env");
            try self.button(clear, "清除请求头", .clear_headers, 0, "settings.mcp.clear_headers");
        }
    }
    fn fieldText(self: *View, field: Field) []const u8 {
        return if (self.fields[@backingInt(field)]) |signal| signal.peek() else "";
    }
    fn apply(self: *View) !void {
        var arena = std.heap.ArenaAllocator.init(self.scope.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var extensions = try self.controller.model.value.ai.extensions.clone(a);
        const index = self.edit_index orelse extensions.servers.len;
        var server: ext.Server = if (self.edit_index) |i| extensions.servers[i] else .{ .id = try std.fmt.allocPrint(a, "{s}", .{std.fmt.bytesToHex(@import("../host/identity.zig").TaskId.generate().bytes, .lower)}), .name = "" };
        server.name = self.fieldText(.name);
        server.transport = self.transport;
        server.timeout_ms = std.fmt.parseInt(u32, self.fieldText(.timeout), 10) catch return error.InvalidMcpTimeout;
        server.roots = try lines(a, self.fieldText(.roots));
        server.oauth_client_id = self.fieldText(.oauth_client_id);
        server.oauth_scope = self.fieldText(.oauth_scope);
        server.bindings = try parseBindings(a, self.fieldText(.bindings));
        if (self.transport == .stdio) {
            server.program = self.fieldText(.program);
            server.args = try lines(a, self.fieldText(.arguments));
            server.cwd = self.fieldText(.cwd);
            if (self.fieldText(.environment).len != 0) server.environment = try parseValues(a, self.fieldText(.environment), '=');
            server.endpoint = "";
            server.headers = &.{};
        } else {
            server.endpoint = self.fieldText(.endpoint);
            if (self.fieldText(.headers).len != 0) server.headers = try parseValues(a, self.fieldText(.headers), ':');
            server.program = "";
            server.args = &.{};
            server.cwd = "";
            server.environment = &.{};
        }
        if (self.edit_index != null) server.revision = try std.math.add(u64, server.revision, 1);
        var list: std.ArrayList(ext.Server) = .empty;
        try list.appendSlice(a, extensions.servers);
        if (index == list.items.len) try list.append(a, server) else list.items[index] = server;
        extensions.servers = list.items;
        try self.controller.setExtensions(extensions);
        self.editing = false;
        self.edit_index = null;
        self.form_values = @splat(null);
        self.fields = @splat(null);
        self.message("");
    }
    fn start(self: *View, kind: Job.Kind, index: ?usize, path: []const u8) !void {
        if (self.job != null or self.controller.state() == .saving) return error.SettingsBusy;
        self.status_area = if ((kind == .test_connection or kind == .authorize)) .mcp else .skills;
        self.status = "";
        self.status_error = false;
        if ((kind == .test_connection or kind == .authorize) and self.serverExpanded(self.controller.model.value.ai.extensions.servers[index.?])) self.detail_open = false;
        const job = try Job.create(self.controller, self.data_root, kind, index, path);
        errdefer job.destroy();
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        self.job = job;
        self.pending = true;
        self.notify();
    }
    const Button = struct {
        view: *View,
        action: Action,
        index: usize,
        fn toggle(self: *@This(), _: bool) void {
            self.click();
        }
        fn click(self: *@This()) void {
            self.run() catch |err| self.view.failure(err);
        }
        fn run(self: *@This()) !void {
            const v = self.view;
            if (self.action == .cancel_job) {
                if (v.job) |job| job.cancel.cancel();
                return;
            }
            if (v.job != null or v.controller.state() == .saving) return error.SettingsBusy;
            var extensions = v.controller.model.value.ai.extensions;
            switch (self.action) {
                .choose_skill, .reimport => {
                    var buffer: [4096]u8 = undefined;
                    const length = zw_pick_skill_path(&buffer, @intCast(buffer.len));
                    if (length < 0) return error.FilePickerUnavailable;
                    if (length == 0) return;
                    try v.start(.import_skill, if (self.action == .reimport) self.index else null, buffer[0..@intCast(length)]);
                },
                .toggle_skill, .remove_skill => {
                    var list: std.ArrayList(ext.Skill) = .empty;
                    defer list.deinit(v.scope.allocator);
                    try list.appendSlice(v.scope.allocator, extensions.skills);
                    if (self.action == .remove_skill) _ = list.orderedRemove(self.index) else list.items[self.index].enabled = !list.items[self.index].enabled;
                    extensions.skills = list.items;
                    try v.controller.setExtensions(extensions);
                    v.status_area = .skills;
                    v.message("");
                },
                .view_skill => {
                    if (v.skillExpanded(extensions.skills[self.index])) {
                        v.detail_open = false;
                        v.pending = true;
                        v.notify();
                    } else try v.start(.read, self.index, "");
                },
                .view_server => {
                    const server = extensions.servers[self.index];
                    const result = v.test_results[self.index] orelse return;
                    if (result.failed or !std.mem.eql(u8, result.id, server.id) or result.revision != server.revision) return;
                    if (v.serverExpanded(server)) {
                        v.detail_open = false;
                    } else {
                        v.detail = result.detail;
                        v.detail_target = .{ .server = .{ .id = result.id, .revision = result.revision } };
                        v.detail_open = true;
                    }
                    v.pending = true;
                    v.notify();
                },
                .new_server, .edit_server => {
                    v.form_values = @splat(null);
                    v.fields = @splat(null);
                    v.editing = true;
                    v.edit_index = if (self.action == .edit_server) self.index else null;
                    v.transport = if (v.edit_index) |i| extensions.servers[i].transport else .stdio;
                    v.pending = true;
                    v.notify();
                },
                .cancel_editor => {
                    v.form_values = @splat(null);
                    v.fields = @splat(null);
                    v.editing = false;
                    v.edit_index = null;
                    v.pending = true;
                    v.notify();
                },
                .stdio, .http => {
                    v.transport = if (self.action == .stdio) .stdio else .http;
                    v.pending = true;
                    v.notify();
                },
                .toggle_server, .remove_server => {
                    if (v.editing) return error.ApplyOrCancelMcpEditor;
                    var arena = std.heap.ArenaAllocator.init(v.scope.allocator);
                    defer arena.deinit();
                    extensions = try extensions.clone(arena.allocator());
                    var list: std.ArrayList(ext.Server) = .empty;
                    try list.appendSlice(arena.allocator(), extensions.servers);
                    if (self.action == .remove_server) _ = list.orderedRemove(self.index) else list.items[self.index].enabled = !list.items[self.index].enabled;
                    extensions.servers = list.items;
                    try v.controller.setExtensions(extensions);
                    v.message("");
                },
                .test_server => try v.start(.test_connection, self.index, ""),
                .authorize_server => try v.start(.authorize, self.index, ""),
                .logout_server => {
                    oauth.logout(v.controller.model.value.ai.extensions.servers[self.index]);
                    v.status_area = .mcp;
                    v.message("");
                },
                .apply => try v.apply(),
                .clear_environment, .clear_headers => {
                    if (v.edit_index) |i| {
                        var arena = std.heap.ArenaAllocator.init(v.scope.allocator);
                        defer arena.deinit();
                        extensions = try extensions.clone(arena.allocator());
                        if (self.action == .clear_environment) extensions.servers[i].environment = &.{} else extensions.servers[i].headers = &.{};
                        extensions.servers[i].revision += 1;
                        try v.controller.setExtensions(extensions);
                        v.message("");
                    }
                },
                .cancel_job => unreachable,
            }
        }
    };
    fn dropEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        if (event != .drag) return .ignored;
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        const drag = event.drag;
        if (drag.kind != .dropped) return .stop;
        if (drag.payload_truncated or drag.payload_kind != .file_or_url) {
            self.failure(error.InvalidFileDrop);
            return .stop;
        }
        var decoded = @import("../local/path_input.zig").decodeDropPaths(self.scope.allocator, drag.paths) catch |err| {
            self.failure(err);
            return .stop;
        };
        defer decoded.deinit();
        if (decoded.paths.len != 1) {
            self.failure(error.ImportOneSkillAtATime);
            return .stop;
        }
        self.start(.import_skill, null, decoded.paths[0]) catch |err| self.failure(err);
        return .stop;
    }
};
pub fn lines(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const value = std.mem.trim(u8, line, " \t\r");
        if (value.len != 0) try result.append(a, value);
    }
    return result.toOwnedSlice(a);
}
pub fn parseValues(a: std.mem.Allocator, text: []const u8, delimiter: u8) ![]ext.Value {
    var values: std.ArrayList(ext.Value) = .empty;
    for (try lines(a, text)) |line| {
        const at = std.mem.indexOfScalar(u8, line, delimiter) orelse return error.InvalidMcpSecret;
        try values.append(a, .{ .name = std.mem.trim(u8, line[0..at], " \t"), .value = std.mem.trim(u8, line[at + 1 ..], " \t"), .secret = true });
    }
    return values.toOwnedSlice(a);
}
fn parseBindings(a: std.mem.Allocator, text: []const u8) ![]const ext.Binding {
    const names = try lines(a, text);
    const result = try a.alloc(ext.Binding, names.len);
    for (names, result) |name, *entry| entry.* = .{ .name = name };
    return result;
}
fn fieldValue(a: std.mem.Allocator, server: ?ext.Server, field: Field) ![]u8 {
    const s = server orelse ext.Server{ .id = "new", .name = "" };
    return switch (field) {
        .name => a.dupe(u8, s.name),
        .program => a.dupe(u8, s.program),
        .arguments => std.mem.join(a, "\n", s.args),
        .cwd => a.dupe(u8, s.cwd),
        .environment, .headers => a.dupe(u8, ""),
        .endpoint => a.dupe(u8, s.endpoint),
        .roots => std.mem.join(a, "\n", s.roots),
        .oauth_client_id => a.dupe(u8, s.oauth_client_id),
        .oauth_scope => a.dupe(u8, s.oauth_scope),
        .timeout => std.fmt.allocPrint(a, "{d}", .{s.timeout_ms}),
        .bindings => blk: {
            const names = try a.alloc([]const u8, s.bindings.len);
            defer a.free(names);
            for (s.bindings, names) |binding, *name| name.* = binding.name;
            break :blk std.mem.join(a, "\n", names);
        },
    };
}
const Job = struct {
    const Kind = enum { import_skill, read, test_connection, authorize };
    browser_pending: std.atomic.Value(bool) = .init(false),
    browser_result: std.atomic.Value(i32) = .init(0),
    browser_url: []const u8 = "",
    arena: std.heap.ArenaAllocator,
    frozen: ext.Extensions,
    root: []const u8,
    path: []const u8,
    kind: Kind,
    index: ?usize,
    draft_id: u64,
    thread: ?std.Thread = null,
    cancel: Cancel = .{},
    done: std.atomic.Value(bool) = .init(false),
    problem: ?anyerror = null,
    imported: std.ArrayList(local.Imported) = .empty,
    diagnostic: local.Diagnostic = .{},
    active_path: []const u8 = "",
    output: []const u8 = "",
    summary: []const u8 = "",
    fn mcpJob(self: *const Job) bool {
        return self.kind == .test_connection or self.kind == .authorize;
    }
    fn openBrowser(raw: *anyopaque, url: []const u8) !void {
        const self: *Job = @ptrCast(@alignCast(raw));
        self.browser_url = try self.arena.allocator().dupe(u8, url);
        self.browser_pending.store(true, .release);
        while (self.browser_result.load(.acquire) == 0) {
            try @import("../ai/retry.zig").wait(10, &self.cancel);
        }
        if (self.browser_result.load(.acquire) < 0) return error.BrowserOpenFailed;
    }
    fn create(c: *Controller, root: []const u8, kind: Kind, index: ?usize, path: []const u8) !*Job {
        const a = std.heap.c_allocator;
        const job = try a.create(Job);
        errdefer a.destroy(job);
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        job.* = .{ .arena = arena, .frozen = try c.model.value.ai.extensions.clone(arena.allocator()), .root = try arena.allocator().dupe(u8, root), .path = try arena.allocator().dupe(u8, path), .kind = kind, .index = index, .draft_id = c.draft_id };
        return job;
    }
    fn destroy(self: *Job) void {
        for (self.imported.items) |*imported| imported.deinit();
        self.imported.deinit(self.arena.allocator());
        for (self.frozen.servers) |server| inline for (.{ "environment", "headers" }) |key| for (@field(server, key)) |entry| if (entry.secret) {
            std.crypto.secureZero(u8, @constCast(entry.value));
        };
        self.arena.deinit();
        std.heap.c_allocator.destroy(self);
    }
    fn run(self: *Job) void {
        self.execute() catch |err| {
            self.problem = err;
            if (!self.mcpJob() and self.active_path.len != 0) {
                const reason = errorMessage(err);
                self.output = std.fmt.allocPrint(self.arena.allocator(), "{s}\n{s}{s}{s}", .{ reason, self.active_path, if (self.diagnostic.path_len != 0) "/" else "", self.diagnostic.path[0..self.diagnostic.path_len] }) catch reason;
            }
        };
        self.done.store(true, .release);
    }
    fn execute(self: *Job) !void {
        var io_threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
        defer io_threaded.deinit();
        const io = io_threaded.io();
        const a = self.arena.allocator();
        if (self.cancel.isCancelled()) return error.Cancelled;
        switch (self.kind) {
            .import_skill => {
                const dir = try std.Io.Dir.cwd().openDir(io, self.root, .{});
                defer dir.close(io);
                self.active_path = self.path;
                const paths = try local.sources(a, io, self.path);
                if (self.index != null and paths.len != 1) return error.SkillReplaceCollection;
                for (paths) |path| {
                    if (self.cancel.isCancelled()) return error.Cancelled;
                    self.active_path = path;
                    var imported = try local.importLocalCancellable(std.heap.c_allocator, io, dir, path, if (self.index) |i| self.frozen.skills[i] else null, &self.diagnostic, &self.cancel);
                    errdefer imported.deinit();
                    for (self.frozen.skills, 0..) |prior, i| {
                        if (self.index != null and self.index.? == i) continue;
                        if (std.mem.eql(u8, prior.name, imported.skill.name)) return error.DuplicateSkill;
                    }
                    for (self.imported.items) |prior| if (std.mem.eql(u8, prior.skill.name, imported.skill.name)) return error.DuplicateSkill;
                    try self.imported.append(a, imported);
                }
            },
            .read => {
                const dir = try std.Io.Dir.cwd().openDir(io, self.root, .{});
                defer dir.close(io);
                self.active_path = self.frozen.skills[self.index.?].name;
                self.output = try local.readDiagnostic(a, io, dir, self.frozen.skills[self.index.?], "SKILL.md", &self.diagnostic);
            },
            .test_connection, .authorize => {
                if (self.kind == .authorize) try oauth.login(a, io, self.frozen.servers[self.index.?], .{ .context = self, .open = openBrowser }, &self.cancel);
                var client = try mcp.Client.init(std.heap.c_allocator, self.frozen.servers[self.index.?]);
                defer client.deinit();
                client.discover(&self.cancel) catch |err| {
                    if (client.rpc_error.len != 0) self.output = try std.fmt.allocPrint(a, "MCP 服务返回错误：{s}", .{client.rpc_error});
                    return err;
                };
                var out: std.Io.Writer.Allocating = .init(a);
                defer out.deinit();
                self.summary = try std.fmt.allocPrint(a, "MCP {s} · {d} 个工具", .{ client.negotiated_version, client.tools.items.len });
                try out.writer.print("{s} · MCP {s} · {d} 个工具\n", .{ self.frozen.servers[self.index.?].name, client.negotiated_version, client.tools.items.len });
                for (client.tools.items) |tool| try out.writer.print("{s} · {s}\n", .{ tool.name, if (tool.available) "可用" else tool.reason });
                self.output = try a.dupe(u8, out.written());
            },
        }
        if (self.cancel.isCancelled()) return error.Cancelled;
    }
};

fn errorMessage(err: anyerror) []const u8 {
    if (@import("../ui/feedback_message.zig").knownMessage(@errorName(err))) |message| return message;
    return switch (err) {
        error.FilePickerUnavailable => "无法打开技能选择器，请重试或拖入技能文件／文件夹。",
        error.SkillReplaceCollection => "重新导入时请选择单个技能文件夹。",
        error.ExtensionLimit => "最多支持 16 个 MCP 服务。",
        error.MissingSkillFile => "未找到 SKILL.md，请选择技能文件或包含技能的目录。",
        error.DuplicateSkill => "同名技能已存在；请使用原条目的重新导入。",
        error.InvalidSkillMetadata => "技能缺少有效的 name / description 元数据。",
        error.MissingSkillResource => "技能引用了缺失的文件；请导入完整文件夹。",
        error.UnsupportedSkillFile => "技能包包含符号链接或不支持的文件类型。",
        error.Cancelled, error.CancelledBeforeDispatch => "操作已取消。",
        error.NoSpaceLeft, error.DiskQuota => "磁盘空间不足，无法导入技能。",
        error.AccessDenied => "无法访问此文件，请检查读取权限。",
        error.InvalidSkillPath => "技能引用包含不支持的路径。",
        error.FileNotFound => "未找到本地路径或技能包，请检查路径。",
        error.McpAuthorizationRequired => "需要授权，请在更多菜单中网页登录。",
        error.McpInsufficientScope => "MCP 授权范围不足，请调整 OAuth Scope 并重新网页登录。",
        error.McpOAuthTokenFailed => "无法获取或刷新授权令牌，请重新网页登录。",
        error.McpOAuthRegistrationFailed => "OAuth 自动注册失败，请检查服务配置或填写预注册的 Client ID。",
        error.McpOAuthResourceMismatch, error.McpOAuthIssuerMismatch => "OAuth 资源地址或授权服务标识不匹配，已停止授权。",
        error.McpOAuthPkceRequired => "授权服务未声明支持 PKCE S256，无法安全完成网页登录。",
        error.McpOAuthCallbackFailed, error.InvalidMcpOAuthCallback => "无法接收有效的本机授权回调，请重新网页登录。",
        error.McpOAuthResponseLimit => "OAuth 响应超过 2 MiB。",
        error.BrowserOpenFailed => "无法打开默认浏览器，请检查系统默认浏览器设置。",
        error.McpOAuthClientIdRequired => "服务未提供自动注册；请填入预注册的 OAuth Client ID。",
        error.McpOAuthPublicClientRequired => "此注册配置不支持公开客户端（token_endpoint_auth_method=none）。",
        error.McpAuthorizationDenied => "已拒绝 MCP 网页授权。",
        error.McpAuthorizationTimeout => "网页授权等待超时，请重新登录。",
        error.McpOAuthStateMismatch => "网页授权回调校验失败，请重新登录。",
        error.McpOAuthDiscoveryFailed, error.InvalidMcpOAuthMetadata => "无法发现有效的 MCP OAuth 授权配置。",
        error.InvalidMcpRoot => "共享根目录需为 file:/// 开头的本地目录 URI。",
        error.InvalidMcpProgram => "stdio 程序和非空工作目录必须使用绝对路径。",
        error.InvalidMcpEndpoint => "HTTP 地址需使用 HTTPS 或本机 HTTP，且不能包含用户名、密码或片段。",
        error.InvalidMcpTimeout => "超时需为 100–120000 毫秒。",
        error.UnsupportedMcpVersion => "服务返回了不支持的 MCP 协议版本。",
        error.InvalidMcpSchema => "MCP 工具参数 schema 无效或引用无法解析。",
        error.McpSchemaLimit => "MCP 单个工具 schema 超过 256 KiB，或工具目录超过 4 MiB。",
        error.McpArgumentsLimit => "MCP 调用参数超过 32 KiB。",
        error.McpResponseLimit, error.McpResultLimit => "MCP 响应超过 32 MiB。",
        error.McpTimeout => "MCP 服务响应超时。",
        error.McpProcessStartFailed => "无法启动 MCP 服务，请检查程序路径与执行权限。",
        error.McpTransportFailure => "MCP 连接中断，请检查服务状态。",
        error.McpHttpStatus => "MCP 服务返回了异常 HTTP 状态。",
        error.McpSecretReflected => "服务响应包含秘密配置，已阻止展示。",
        else => blk: {
            std.log.warn("extension settings operation failed: {s}", .{@errorName(err)});
            break :blk "未能完成操作。请检查扩展配置后重试。";
        },
    };
}
