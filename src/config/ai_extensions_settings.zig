//! Native settings forms; imports and connection tests use owned, isolated jobs.
const std = @import("std");
const ui = @import("ui");
const ext = @import("ai_extensions.zig");
const Controller = @import("settings_controller.zig").Controller;
const S = @import("settings_styles.zig");
const controls = @import("settings_parts/settings_controls.zig");
const local = @import("../ai/local_skills.zig");
const mcp = @import("../ai/mcp_client.zig");
const Cancel = @import("../ai/provider.zig").CancelToken;
pub const Hooks = struct { context: *anyopaque, changed: *const fn (*anyopaque) void };
const Field = enum { name, program, arguments, cwd, environment, endpoint, headers, timeout, bindings };
const Action = enum { import_path, choose_file, choose_folder, cancel_job, toggle_skill, reimport, view_skill, remove_skill, new_server, edit_server, toggle_server, remove_server, test_server, apply, cancel_editor, stdio, http, clear_environment, clear_headers };
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
    detail: []const u8 = "",
    path: ?*ui.Signal([]const u8) = null,
    path_value: []const u8 = "",
    test_results: [16]?struct { id: []const u8, revision: u64, label: []const u8 } = @splat(null),
    form_values: [9]?[]const u8 = @splat(null),
    editing: bool = false,
    edit_index: ?usize = null,
    transport: @FieldType(ext.Server, "transport") = .stdio,
    fields: [9]?*ui.Signal([]const u8) = @splat(null),
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
        self.status = controls.owned(self.scope, content) catch "操作失败";
        self.pending = true;
        self.notify();
    }
    fn failure(self: *View, err: anyerror) void {
        self.message(switch (err) {
            error.DuplicateSkill => "同名技能已存在；请使用原条目的重新导入。",
            error.InvalidSkillMetadata => "技能缺少有效的 name / description 元数据。",
            error.MissingSkillResource => "技能引用了缺失的文件；请导入完整文件夹。",
            error.UnsupportedSkillFile => "技能包包含符号链接或不支持的文件类型。",
            error.FileNotFound => "未找到本地路径或技能包，请检查路径。",
            error.InvalidMcpProgram => "stdio 程序和非空工作目录必须使用绝对路径。",
            error.InvalidMcpEndpoint => "HTTP 地址需使用 HTTPS 或本机 HTTP，且不能包含用户名、密码或片段。",
            error.InvalidMcpTimeout => "超时需为 100–120000 毫秒。",
            error.McpSecretReflected => "服务响应包含秘密配置，已阻止展示。",
            else => @errorName(err),
        });
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.job) |job| {
            if (job.done.load(.acquire)) {
                job.thread.?.join();
                self.job = null;
                defer job.destroy();
                if (job.kind == .test_connection and job.draft_id == self.controller.draft_id) {
                    const i = job.index.?;
                    const server = job.frozen.servers[i];
                    const label = if (job.problem) |err| tryLabel: {
                        break :tryLabel @errorName(err);
                    } else job.summary;
                    self.test_results[i] = .{ .id = controls.owned(self.scope, server.id) catch "", .revision = server.revision, .label = controls.owned(self.scope, label) catch "测试结果无法保留" };
                }
                if (job.draft_id != self.controller.draft_id or self.controller.state() == .saving) self.message("设置草稿已变化，本次结果已丢弃。") else if (job.problem) |err| self.failure(err) else {
                    if (job.imported) |imported| {
                        var extensions = self.controller.model.value.ai.extensions;
                        var list: std.ArrayList(ext.Skill) = .empty;
                        defer list.deinit(self.scope.allocator);
                        list.appendSlice(self.scope.allocator, extensions.skills) catch return .done;
                        if (job.index) |i| {
                            if (i >= list.items.len or !std.mem.eql(u8, list.items[i].id, job.frozen.skills[i].id)) {
                                self.message("技能选择已变化，请重新导入。");
                                return .needs_layout;
                            }
                            list.items[i] = imported.skill;
                        } else list.append(self.scope.allocator, imported.skill) catch return .done;
                        extensions.skills = list.items;
                        self.controller.setExtensions(extensions) catch |err| {
                            self.failure(err);
                            return .needs_layout;
                        };
                        self.message("已导入草稿。保存后可用于新任务；原任务继续读取已固定的版本。");
                    } else if (job.kind == .read) {
                        self.detail = controls.owned(self.scope, job.output) catch "";
                        self.message("技能正文 · 只读；内容不会授予工具权限。");
                    } else {
                        self.detail = controls.owned(self.scope, job.output) catch "";
                        self.message("连接测试完成：只初始化并读取工具清单，未调用业务工具。");
                    }
                }
                self.pending = true;
            } else self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
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
    fn card(self: *View, title: []const u8, hint: []const u8, id: []const u8, icon: ui.SvgAsset, bit: u6) !*ui.Node {
        const scope = self.render_scope.?;
        const fold = try scope.createState(Fold, .{ .view = self, .bit = bit });
        const expanded = self.controller.search_query.len != 0 or self.controller.folded_sections & (@as(u64, 1) << bit) == 0;
        const result = try @import("settings_accordion.zig").item(.{ .title = title, .expanded = expanded, .on_change = self.cx.on(Fold, fold, Fold.change), .variant = .ghost }).mount(scope, self.cx);
        _ = try controls.sectionHeader(self.cx, scope, result, icon, expanded, hint, id);
        result.item.meta.ownership.meta.test_id = id;
        result.header.meta.ownership.meta.test_id = try controls.stableId(scope, id, ".header");
        if (self.controller.state() == .saving or self.controller.search_query.len != 0) {
            result.header.behavior.events.on_event = null;
            result.header.setFocusable(false);
        }
        result.body.setStyleInline(self.cx.allocator, S.column(undefined));
        result.body.setStyleInline(self.cx.allocator, .{ .padding = .{ .left = 16, .right = 16, .bottom = 8 }, .gap = 10 });
        try self.root.appendChild(self.cx.allocator, result.item);
        try self.text(result.body, hint, false);
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
        if (self.path) |signal| self.path_value = try controls.owned(self.scope, signal.peek());
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
        self.path = null;
        const skills_card = try self.card("本地技能", "导入 SKILL.md 或文件夹。资源仅复制、只读；不运行脚本。保存后生效。", "settings.ai.skills", ui.icons.sparkles, 31);
        const drop = try ui.boxStyled(self.cx, S.column, .{});
        drop.style.width = .fill();
        drop.style.gap = 6;
        drop.meta.ownership.meta.test_id = "settings.skills.drop";
        drop.behavior.events.on_event = dropEvent;
        drop.behavior.events.event_context = self;
        self.path = try self.input(drop, "拖入技能文件 / 文件夹，或输入绝对路径", self.path_value, "settings.skills.path", false, false);
        const import_row = try self.row(drop);
        try self.button(import_row, "导入路径", .import_path, 0, "settings.skills.import");
        try self.button(import_row, "选择文件", .choose_file, 0, "settings.skills.file");
        try self.button(import_row, "选择文件夹", .choose_folder, 0, "settings.skills.folder");
        try skills_card.appendChild(self.cx.allocator, drop);
        for (self.controller.model.value.ai.extensions.skills, 0..) |skill, i| {
            try self.text(skills_card, skill.name, true);
            try self.text(skills_card, skill.description, false);
            const row_node = try self.row(skills_card);
            var id: [96]u8 = undefined;
            try self.button(row_node, if (skill.enabled) "停用" else "启用", .toggle_skill, i, try std.fmt.bufPrint(&id, "settings.skill.{d}.toggle", .{i}));
            try self.button(row_node, "查看", .view_skill, i, try std.fmt.bufPrint(&id, "settings.skill.{d}.view", .{i}));
            try self.button(row_node, "重新导入路径", .reimport, i, try std.fmt.bufPrint(&id, "settings.skill.{d}.reimport", .{i}));
            try self.button(row_node, "移除", .remove_skill, i, try std.fmt.bufPrint(&id, "settings.skill.{d}.remove", .{i}));
        }
        const mcp_card = try self.card("MCP 服务", "仅显式测试或工具调用时连接。只开放已绑定的材料文本工具；其他工具显示为不可用。", "settings.ai.mcp", ui.icons.plug, 32);
        for (self.controller.model.value.ai.extensions.servers, 0..) |server, i| {
            try self.text(mcp_card, server.name, true);
            const test_result = self.test_results[i];
            try self.text(mcp_card, if (test_result != null and std.mem.eql(u8, test_result.?.id, server.id) and test_result.?.revision == server.revision) test_result.?.label else "未测试 · 连接状态与当前任务可用能力分别判断", false);
            try self.text(mcp_card, if (server.transport == .stdio) "stdio · 直接启动程序，不经过 shell" else "Streamable HTTP · 2025-11-25", false);
            const row_node = try self.row(mcp_card);
            var id: [96]u8 = undefined;
            try self.button(row_node, if (server.enabled) "停用" else "启用", .toggle_server, i, try std.fmt.bufPrint(&id, "settings.mcp.{d}.toggle", .{i}));
            try self.button(row_node, "编辑", .edit_server, i, try std.fmt.bufPrint(&id, "settings.mcp.{d}.edit", .{i}));
            try self.button(row_node, "测试连接", .test_server, i, try std.fmt.bufPrint(&id, "settings.mcp.{d}.test", .{i}));
            try self.button(row_node, "移除", .remove_server, i, try std.fmt.bufPrint(&id, "settings.mcp.{d}.remove", .{i}));
        }
        if (self.editing) try self.form(mcp_card) else try self.button(mcp_card, "添加 MCP 服务", .new_server, 0, "settings.mcp.add");
        if (self.job != null) {
            try self.text(self.root, "正在处理…", false);
            try self.button(self.root, "取消", .cancel_job, 0, "settings.extensions.cancel");
        }
        if (self.status.len != 0) try self.text(self.root, self.status, false);
        if (self.detail.len != 0) {
            const value = try self.render_scope.?.createText(self.detail, .{});
            const preview = try ui.widgets.Textarea(.{ .value = value, .rows = @as(u32, 6), .readonly = true }).mount(self.render_scope.?, self.cx);
            preview.meta.ownership.meta.test_id = "settings.extensions.detail";
            try self.root.appendChild(self.cx.allocator, preview);
        }
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
                .endpoint, .headers => self.transport == .http,
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
                    .bindings => "材料工具绑定 · 每行一个远端工具名（只接受唯一必填 text 字段）",
                };
                self.fields[field_index] = try self.input(parent, label, initial, "settings.mcp.field." ++ field_name, key == .environment or key == .headers, key == .arguments or key == .bindings or key == .environment or key == .headers);
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
        self.message("服务已应用到草稿；请保存设置。");
    }
    fn start(self: *View, kind: Job.Kind, index: ?usize, path: []const u8) !void {
        if (self.job != null or self.controller.state() == .saving) return error.SettingsBusy;
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
                .import_path, .reimport => try v.start(.import_skill, if (self.action == .reimport) self.index else null, v.path.?.peek()),
                .choose_file, .choose_folder => {
                    var buffer: [4096]u8 = undefined;
                    const sdk = v.cx.system_sdk orelse return error.FilePickerUnavailable;
                    const path = (try sdk.runDialog(.{ .kind = if (self.action == .choose_folder) .pick_folder else .open_file }, &buffer)) orelse return;
                    try v.start(.import_skill, null, path);
                },
                .toggle_skill, .remove_skill => {
                    var list: std.ArrayList(ext.Skill) = .empty;
                    defer list.deinit(v.scope.allocator);
                    try list.appendSlice(v.scope.allocator, extensions.skills);
                    if (self.action == .remove_skill) _ = list.orderedRemove(self.index) else list.items[self.index].enabled = !list.items[self.index].enabled;
                    extensions.skills = list.items;
                    try v.controller.setExtensions(extensions);
                    v.message("技能更改已进入草稿。");
                },
                .view_skill => try v.start(.read, self.index, ""),
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
                    v.message("服务更改已进入草稿。");
                },
                .test_server => try v.start(.test_connection, self.index, ""),
                .apply => try v.apply(),
                .clear_environment, .clear_headers => {
                    if (v.edit_index) |i| {
                        var arena = std.heap.ArenaAllocator.init(v.scope.allocator);
                        defer arena.deinit();
                        extensions = try extensions.clone(arena.allocator());
                        if (self.action == .clear_environment) extensions.servers[i].environment = &.{} else extensions.servers[i].headers = &.{};
                        extensions.servers[i].revision += 1;
                        try v.controller.setExtensions(extensions);
                        v.message("秘密项已从草稿移除。");
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
    const Kind = enum { import_skill, read, test_connection };
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
    imported: ?local.Imported = null,
    output: []const u8 = "",
    summary: []const u8 = "",
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
        if (self.imported) |*imported| imported.deinit();
        for (self.frozen.servers) |server| inline for (.{ "environment", "headers" }) |key| for (@field(server, key)) |entry| if (entry.secret) {
            std.crypto.secureZero(u8, @constCast(entry.value));
        };
        self.arena.deinit();
        std.heap.c_allocator.destroy(self);
    }
    fn run(self: *Job) void {
        self.execute() catch |err| {
            self.problem = err;
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
                self.imported = try local.importLocal(std.heap.c_allocator, io, dir, self.path, if (self.index) |i| self.frozen.skills[i] else null);
            },
            .read => {
                const dir = try std.Io.Dir.cwd().openDir(io, self.root, .{});
                defer dir.close(io);
                self.output = try local.read(a, io, dir, self.frozen.skills[self.index.?], "SKILL.md");
            },
            .test_connection => {
                var client = try mcp.Client.init(std.heap.c_allocator, self.frozen.servers[self.index.?]);
                defer client.deinit();
                try client.discover(&self.cancel);
                var out: std.Io.Writer.Allocating = .init(a);
                defer out.deinit();
                var available: usize = 0;
                for (client.tools.items) |tool| if (tool.available) {
                    available += 1;
                };
                self.summary = try std.fmt.allocPrint(a, "协议已连接 · {d} 个工具 · {d} 个材料适配可用", .{ client.tools.items.len, available });
                try out.writer.print("{s} · MCP {s} · {d} 个工具\n", .{ self.frozen.servers[self.index.?].name, mcp.version, client.tools.items.len });
                for (client.tools.items) |tool| try out.writer.print("{s} · {s}\n", .{ tool.name, if (tool.available) "材料文本可用" else tool.reason });
                self.output = try a.dupe(u8, out.written());
            },
        }
        if (self.cancel.isCancelled()) return error.Cancelled;
    }
};
