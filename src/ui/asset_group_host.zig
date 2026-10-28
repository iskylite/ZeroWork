//! Asset-group dialogs and the small workspace adapter. No session lifecycle or
//! terminal group operation is reachable through this host.
const std = @import("std");
const ui = @import("ui");
const Workspace = @import("workspace.zig").Workspace;
const Sidebar = @import("sidebar_view.zig");
const Owned = @import("session_lifecycle.zig").Snapshot;
pub const actions = @import("../config/asset_group_actions.zig");
const S = @import("asset_group_styles.zig");
pub const GroupRef = actions.GroupRef;
pub const Mode = S.Mode;
pub const NewHost = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, ?GroupRef) anyerror!void,
};
pub const GroupSnapshot = struct {
    reference: GroupRef,
    name: []const u8,
    color: []const u8,
    collapsed: bool = false,
    host_count: usize = 0,
};
pub const Callbacks = struct {
    context: *anyopaque,
    anchor: ?*const fn (*anyopaque, ?GroupRef) ?*ui.Node = null,
    submit: *const fn (*anyopaque, actions.Request) anyerror!actions.Result,
    new_host: *const fn (*anyopaque, ?GroupRef) anyerror!void,
};

pub const View = struct {
    anchor_rect: ui.widgets.popover.AnchorRect = .{ .x = 8, .y = 40, .w = 24, .h = 24 },
    cx: *ui.Cx,
    callbacks: Callbacks,
    open: *ui.Signal(bool),
    value: *ui.Signal([]const u8),
    disabled: *ui.Signal(bool),
    primary_style: *ui.Signal(ui.BoxStyle),
    secondary_style: *ui.Signal(ui.BoxStyle),
    hover_style: *ui.Signal(?ui.BoxStyle),
    source: ?Owned(GroupSnapshot) = null,
    receipt: ?actions.Result = null,
    mode: Mode = .create,
    pending: bool = false,
    pending_new_host: bool = false,
    queued_new_host: ?struct { reference: ?GroupRef } = null,
    focus_pending: bool = false,
    failure: ?anyerror = null,
    root: *ui.Node = undefined,
    dialog: *ui.Node = undefined,
    header_icon: *ui.Node = undefined,
    close_icon: *ui.Node = undefined,
    title: *ui.Node = undefined,
    summary: *ui.Node = undefined,
    folder: *ui.Node = undefined,
    name: *ui.Node = undefined,
    count: *ui.Node = undefined,
    field: *ui.Node = undefined,
    field_label: *ui.Node = undefined,
    input: ui.widgets.input.InputResult = undefined,
    helper: *ui.Node = undefined,
    notice: *ui.Node = undefined,
    notice_title: *ui.Node = undefined,
    notice_detail: *ui.Node = undefined,
    primary: *ui.Node = undefined,
    primary_label: *ui.Node = undefined,
    secondary: *ui.Node = undefined,
    secondary_label: *ui.Node = undefined,
    colors: S.theme.Colors,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{
            .cx = cx,
            .callbacks = callbacks,
            .open = try scope.createSignal(bool, false),
            .value = try scope.createText("", .{}),
            .disabled = try scope.createSignal(bool, false),
            .primary_style = try scope.createSignal(ui.BoxStyle, S.button(116, 30, true, false)),
            .secondary_style = try scope.createSignal(ui.BoxStyle, S.button(84, 30, false, false)),
            .hover_style = try scope.createSignal(?ui.BoxStyle, S.hover()),
            .colors = S.theme.current(),
        });
        try scope.onCleanup(View, self, release);
        const popup = try ui.widgets.Popover(.{ .open = self.open, .trigger = .manual, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchorRect } }, .position = .bottom_start, .offset = .{ .static = 6 }, .width = S.width, .max_height = 600, .viewport_padding = 8, .constrain_width_to_viewport = true, .shift_main_axis = true, .consume_outside_click = true, .a11y_role = .dialog, .on_open_change = cx.on(View, self, openChanged) }).mount(scope, cx);
        self.root = popup.wrapper;
        self.dialog = popup.chrome;
        self.dialog.meta.ownership.meta.test_id = "asset.group.dialog";
        self.dialog.setStyleInline(cx.allocator, S.panel(.create, cx.viewport, false, false));
        const content = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .padding = ui.Padding.ZERO, .gap = 0 }, .{});
        try popup.content.appendChild(cx.allocator, content);
        if (cx.root) |root| try root.appendChild(cx.allocator, popup.wrapper);
        const header = try ui.box(cx, S.header(), .{});
        self.header_icon = try ui.iconTint(cx, ui.icons.get("folder-plus").?, S.theme.current().accent, S.icon(18));
        try header.appendChild(cx.allocator, self.header_icon);
        self.title = try self.label(header, "创建资产分组", 20, S.text(13, 700, false));
        self.title.setStyleInline(cx.allocator, .{ .flex = 1, .min_width = 0 });
        const close = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "关闭分组操作", .base_style = S.close(), .hover_style = self.hover_style, .on_click = cx.on(View, self, hide) }).mount(scope, cx);
        close.meta.ownership.meta.test_id = "asset.group.close";
        self.close_icon = try ui.iconTint(cx, ui.icons.x, S.theme.current().fg_2, S.icon(16));
        try close.appendChild(cx.allocator, self.close_icon);
        try header.appendChild(cx.allocator, close);
        try content.appendChild(cx.allocator, header);
        const body = try ui.box(cx, S.body(), .{});
        try content.appendChild(cx.allocator, body);
        self.summary = try ui.box(cx, S.summary(), .{});
        self.folder = try ui.iconTint(cx, ui.icons.folder, S.theme.current().accent, S.icon(18));
        try self.summary.appendChild(cx.allocator, self.folder);
        self.name = try self.label(self.summary, "新分组", 18, S.text(12, 500, false));
        self.name.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
        self.count = try self.label(self.summary, "0 台主机", 16, S.text(11, 400, false));
        self.count.setStyleInline(cx.allocator, .{ .width = .{ .px = 94 } });
        try body.appendChild(cx.allocator, self.summary);
        self.field = try ui.box(cx, S.field(false), .{});
        self.field_label = try self.label(self.field, "分组名称", 16, S.text(11, 500, false));
        self.input = try ui.widgets.Input(.{ .value = self.value, .disabled = self.disabled, .on_change = cx.on(View, self, changed), .on_submit = cx.on(View, self, inputSubmit) }).mountResult(scope, cx);
        @import("app_theme.zig").styleInput(self.input);
        self.input.input_container.setStyleInline(cx.allocator, S.input());
        self.input.input_container.meta.ownership.meta.test_id = "asset.group.input";
        S.tuneInput(&self.input);
        try self.field.appendChild(cx.allocator, self.input.node);
        self.helper = try self.label(self.field, "", 16, S.text(10.5, 400, false));
        self.helper.meta.ownership.meta.test_id = "asset.group.error";
        try body.appendChild(cx.allocator, self.field);
        self.notice = try ui.box(cx, S.notice(.create, false), .{});
        self.notice_title = try self.label(self.notice, "创建空的资产分组", 18, S.text(12, 500, false));
        self.notice_detail = try self.label(self.notice, "创建后可添加或移入主机。", 16, S.paragraph());
        try body.appendChild(cx.allocator, self.notice);
        const footer = try ui.box(cx, S.footer(), .{});
        self.secondary = try ui.widgets.Button(.{ .variant = .secondary, .a11y_label = "取消或添加主机", .disabled = self.disabled, .base_style = self.secondary_style, .hover_style = self.hover_style, .on_click = cx.on(View, self, secondaryAction) }).mount(scope, cx);
        self.secondary.meta.ownership.meta.test_id = "asset.group.secondary";
        self.secondary_label = try self.label(self.secondary, "取消", 18, S.text(12, 500, false));
        self.secondary_label.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} } });
        try footer.appendChild(cx.allocator, self.secondary);
        self.primary = try ui.widgets.Button(.{ .variant = .primary, .a11y_label = "确认分组操作", .disabled = self.disabled, .base_style = self.primary_style, .on_click = cx.on(View, self, submit) }).mount(scope, cx);
        self.primary.meta.ownership.meta.test_id = "asset.group.primary";
        self.primary_label = try self.label(self.primary, "创建分组", 18, S.text(12, 500, false));
        self.primary_label.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} } });
        try footer.appendChild(cx.allocator, self.primary);
        try body.appendChild(cx.allocator, footer);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    fn anchorRect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.callbacks.anchor) |resolve| if (resolve(self.callbacks.context, if (self.mode == .created) null else if (self.source) |source| source.value.reference else null)) |node| {
            const rect = node.globalRect();
            self.anchor_rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
        };
        return self.anchor_rect;
    }
    pub fn show(self: *View, mode: Mode, source: ?GroupSnapshot) !void {
        if (mode == .created or (mode != .create and source == null) or (mode == .create and source != null)) return error.InvalidGroupDialog;
        const next = if (source) |value| try Owned(GroupSnapshot).init(self.cx.allocator, value) else null;
        if (self.source) |*old| old.deinit();
        self.source = next;
        self.receipt = null;
        self.mode = mode;
        self.failure = null;
        self.pending = false;
        self.pending_new_host = false;
        self.queued_new_host = null;
        self.disabled.set(false);
        self.value.set(if (mode == .create) "" else if (mode == .color) source.?.color else source.?.name);
        self.open.set(true);
        self.focus_pending = true;
        try self.refresh();
    }
    pub fn isVisible(self: *const View) bool {
        return self.open.peek();
    }
    pub fn hide(self: *View) void {
        self.pending = false;
        self.pending_new_host = false;
        self.queued_new_host = null;
        self.focus_pending = false;
        self.disabled.set(false);
        self.open.set(false);
        if (self.callbacks.anchor) |resolve| if (resolve(self.callbacks.context, if (self.mode == .created) null else if (self.source) |source| source.value.reference else null)) |node| self.cx.setFocus(node);
    }
    pub fn submit(self: *View) void {
        if (!self.isVisible() or self.pending or self.input.state.imeIsComposing()) return;
        if (self.mode == .created) {
            self.hide();
            return;
        }
        if (self.mode == .delete_empty and self.source.?.value.host_count != 0) {
            self.fail(error.GroupNotEmpty);
            return;
        }
        self.pending = true;
        self.disabled.set(true);
        self.cx.requestRedraw();
    }
    fn inputSubmit(self: *View, _: []const u8) void {
        if (self.mode != .delete_empty) self.submit();
    }
    fn secondaryAction(self: *View) void {
        if (self.mode != .created) {
            self.hide();
            return;
        }
        self.pending_new_host = true;
        self.cx.requestRedraw();
    }
    fn changed(self: *View, _: []const u8) void {
        self.failure = null;
        self.refresh() catch {};
    }
    fn openChanged(self: *View, value: bool) void {
        if (!value) self.hide();
    }
    fn request(self: *const View) actions.Request {
        const reference = if (self.source) |source| source.value.reference else undefined;
        return switch (self.mode) {
            .create => .{ .create = .{ .name = self.value.peek() } },
            .rename => .{ .rename = .{ .group = reference, .name = self.value.peek() } },
            .color => .{ .color = .{ .group = reference, .color = self.value.peek() } },
            .delete_empty => .{ .delete_empty = reference },
            .created => unreachable,
        };
    }
    fn commitPending(self: *View) void {
        self.pending = false;
        const request_value = self.request();
        const result = self.callbacks.submit(self.callbacks.context, request_value) catch |err| {
            self.fail(err);
            return;
        };
        const original = if (self.source) |source| source.value.reference else null;
        const target_matches = if (result.group) |target| @backingInt(target.id) != 0 and target.revision != 0 and (if (original) |previous| previous.id == target.id and target.revision > previous.revision else true) else result.kind == .delete_empty;
        if (result.kind != std.meta.activeTag(request_value) or !std.meta.eql(result.source_group, original) or result.commit.revision <= result.commit.previous_revision or !target_matches or (result.kind == .delete_empty and result.group != null)) {
            self.fail(error.InvalidCommitReceipt);
            return;
        }
        self.disabled.set(false);
        self.receipt = result;
        if (self.mode == .create) {
            const created: GroupSnapshot = .{ .reference = result.group.?, .name = std.mem.trim(u8, self.value.peek(), " \t\r\n"), .color = request_value.create.color };
            self.source = Owned(GroupSnapshot).init(self.cx.allocator, created) catch {
                self.hide();
                return;
            };
            self.mode = .created;
            self.focus_pending = true;
            self.refresh() catch {};
        } else self.hide();
    }
    fn fail(self: *View, err: anyerror) void {
        self.failure = err;
        self.disabled.set(false);
        self.refresh() catch {};
    }
    fn fieldError(self: *const View) bool {
        return if (self.failure) |err| switch (err) {
            error.InvalidGroup, error.DuplicateGroupName, error.InvalidGroupColor => true,
            else => false,
        } else false;
    }
    fn refresh(self: *View) !void {
        const c = S.theme.current();
        self.dialog.setStyleInline(self.cx.allocator, S.panel(self.mode, self.cx.viewport, self.fieldError(), self.failure != null and !self.fieldError()));
        self.summary.setStyleInline(self.cx.allocator, S.summary());
        self.summary.setDisplay(if (self.mode == .delete_empty or self.mode == .created) .flex else .none);
        self.field.setStyleInline(self.cx.allocator, S.field(self.fieldError()));
        self.helper.setDisplay(if (self.fieldError()) .flex else .none);
        self.notice.setDisplay(if (self.mode == .delete_empty or (self.failure != null and !self.fieldError())) .flex else .none);
        self.notice.setStyleInline(self.cx.allocator, S.notice(self.mode, self.failure != null));
        self.field.setDisplay(if (self.mode == .created or self.mode == .delete_empty) .none else .flex);
        self.input.input_container.setStyleInline(self.cx.allocator, S.input());
        S.tuneInput(&self.input);
        self.hover_style.set(S.hover());
        self.primary_style.set(S.button(if (self.mode == .created) 96 else 116, 30, true, self.mode == .delete_empty));
        self.secondary_style.set(S.button(if (self.mode == .created) 116 else 84, 30, false, false));
        const title = switch (self.mode) {
            .create => "创建资产分组",
            .created => "资产分组已创建",
            .rename => "重命名分组",
            .color => "更改组色",
            .delete_empty => "删除空分组",
        };
        try self.title.setTextContent(self.cx.allocator, title);
        try self.field_label.setTextContent(self.cx.allocator, if (self.mode == .color) "分组颜色" else "分组名称");
        const name = if (self.mode == .create or self.mode == .rename) std.mem.trim(u8, self.value.peek(), " \t\r\n") else if (self.source) |source| source.value.name else "";
        try self.name.setTextContent(self.cx.allocator, if (name.len == 0) "新分组" else name);
        var count_buffer: [64]u8 = undefined;
        try self.count.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&count_buffer, "{d} 台主机", .{if (self.source) |source| source.value.host_count else @as(usize, 0)}));
        try self.helper.setTextContent(self.cx.allocator, if (self.failure) |err| errorText(err) else "");
        const notice_title = if (self.failure != null) "保存失败" else switch (self.mode) {
            .create => "创建空的资产分组",
            .created => "分组已创建",
            .rename => "保存分组名称",
            .color => "保存分组颜色",
            .delete_empty => "确认删除这个空分组？",
        };
        try self.notice_title.setTextContent(self.cx.allocator, notice_title);
        self.notice_title.setDisplay(if (self.failure != null or self.mode == .delete_empty) .flex else .none);
        const detail = if (self.failure) |err| errorText(err) else switch (self.mode) {
            .create => "创建后可添加或移入主机。",
            .created => "可继续添加或移入主机。",
            .rename, .color => "分组中的主机将保留在原分组。",
            .delete_empty => "删除后可重新创建分组。",
        };
        try self.notice_detail.setTextContent(self.cx.allocator, detail);
        try self.primary_label.setTextContent(self.cx.allocator, switch (self.mode) {
            .create => "创建分组",
            .created => "完成",
            .delete_empty => "删除空分组",
            else => "保存",
        });
        try self.secondary_label.setTextContent(self.cx.allocator, if (self.mode == .created) "添加主机" else "取消");
        self.title.setTextColor(c.fg_1);
        self.name.setTextColor(c.fg_1);
        self.count.setTextColor(c.fg_2);
        self.field_label.setTextColor(c.fg_2);
        self.helper.setTextColor(if (self.failure != null) c.danger_ink else c.fg_2);
        self.notice_title.setTextColor(S.ink(self.mode, self.failure != null));
        self.notice_detail.setTextColor(c.fg_2);
        self.secondary_label.setTextColor(c.fg_2);
        self.primary_label.setTextColor(self.cx.tokens.tokens.color.button_primary_fg);
        const header_asset = ui.icons.get(if (self.mode == .created) "folder-check" else "folder-plus").?;
        if (header_asset.icon_id) |id| if (header_asset.pickRep(18)) |rep| self.header_icon.setIcon(.{ .icon_id = id, .rep = rep, .tint = if (self.mode == .created) c.ok else c.accent });
        _ = self.close_icon.setTint(c.fg_2);
        const hex = if (self.mode == .color) self.value.peek() else if (self.source) |source| source.value.color else "#6366f1";
        _ = self.folder.setTint(if (actions.colorValid(hex)) ui.Color.hex(std.fmt.parseInt(u24, hex[1..], 16) catch 0) else c.accent);
        self.colors = c;
        self.cx.requestRedraw();
    }
    fn label(self: *View, parent: *ui.Node, text: []const u8, height: f32, style: ui.TextStyle) !*ui.Node {
        const node = try ui.text(self.cx, text, style);
        node.setStyleInline(self.cx.allocator, S.label(height));
        try parent.appendChild(self.cx.allocator, node);
        return node;
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.queued_new_host) |queued| {
            if (self.cx.focus_manager.activeScope() == self.root) {
                self.cx.scheduleRedrawAfterNs(std.time.ns_per_ms);
                return .done;
            }
            self.queued_new_host = null;
            self.callbacks.new_host(self.callbacks.context, queued.reference) catch |err| {
                self.open.set(true);
                self.focus_pending = true;
                self.fail(err);
            };
        }
        if (!self.isVisible()) return .done;
        if (self.pending) self.commitPending();
        if (self.pending_new_host) {
            self.pending_new_host = false;
            const reference = if (self.source) |source| source.value.reference else null;
            self.hide();
            self.queued_new_host = .{ .reference = reference };
            self.cx.scheduleRedrawAfterNs(std.time.ns_per_ms);
            return .done;
        }
        const expected = S.panel(self.mode, self.cx.viewport, self.fieldError(), self.failure != null and !self.fieldError());
        const resized = !std.meta.eql(expected.width, self.dialog.style.width) or !std.meta.eql(expected.height, self.dialog.style.height);
        if (resized or !std.meta.eql(self.colors, S.theme.current())) self.refresh() catch {};
        if (self.focus_pending and self.isVisible() and self.dialog.globalRect().w > 0) {
            self.focus_pending = false;
            self.cx.setFocus(if (self.mode == .delete_empty) self.secondary else if (self.mode == .created) self.primary else self.input.input_container);
        }
        return if (resized) .needs_layout else .done;
    }
    fn release(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.source) |*source| source.deinit();
    }
};

pub const Host = struct {
    cx: *ui.Cx,
    workspace: *Workspace,
    new_host: NewHost,
    view: *View = undefined,
    pending_toggle: ?GroupRef = null,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, workspace: *Workspace, new_host: NewHost) !*Host {
        const self = try scope.createState(Host, .{ .cx = cx, .workspace = workspace, .new_host = new_host });
        try scope.onCleanup(Host, self, release);
        self.view = try View.mount(cx, scope, .{ .context = self, .submit = submit, .new_host = openNewHost, .anchor = resolveAnchor });
        try workspace.setSidebarBridge(.{ .context = self, .new_host = newHost, .new_group = newGroup, .group_action = groupAction, .set_anchor = setAnchor });
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    pub fn isVisible(self: *const Host) bool {
        return self.view.isVisible();
    }
    fn snapshot(self: *Host, reference: GroupRef) !GroupSnapshot {
        const value = try actions.group(&self.workspace.registry, reference);
        var count: usize = 0;
        for (self.workspace.registry.hosts) |host| if (host.asset_group_id == reference.id) {
            count += 1;
        };
        return .{ .reference = reference, .name = value.name, .color = value.color, .collapsed = value.collapsed, .host_count = count };
    }
    fn newHost(raw: ?*anyopaque, reference: ?GroupRef) void {
        const self: *Host = @ptrCast(@alignCast(raw orelse return));
        openNewHost(self, reference) catch |err| self.workspace.status(errorText(err));
    }
    fn openNewHost(raw: *anyopaque, reference: ?GroupRef) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (reference) |value| _ = try actions.group(&self.workspace.registry, value);
        try self.new_host.open(self.new_host.context, reference);
    }
    fn resolveAnchor(raw: *anyopaque, reference: ?GroupRef) ?*ui.Node {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (reference) |group| {
            for (self.workspace.group_rows.items) |row| if (row.reference) |value| if (value.id == group.id) return row.menu.trigger;
            return null;
        }
        if (self.workspace.sidebar_chrome) |sidebar| return sidebar.new_menu.trigger;
        return null;
    }
    fn setAnchor(raw: ?*anyopaque, rect: ui.ComputedRect) void {
        const self: *Host = @ptrCast(@alignCast(raw orelse return));
        self.view.anchor_rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    }
    fn newGroup(raw: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(raw orelse return));
        self.view.show(.create, null) catch |err| self.workspace.status(errorText(err));
    }
    fn groupAction(raw: ?*anyopaque, reference: GroupRef, action: Sidebar.GroupAction) void {
        const self: *Host = @ptrCast(@alignCast(raw orelse return));
        if (action == .new_host) return newHost(self, reference);
        const source = self.snapshot(reference) catch |err| {
            self.workspace.status(errorText(err));
            return;
        };
        switch (action) {
            .toggle_collapsed => {
                self.pending_toggle = reference;
                self.cx.requestRedraw();
            },
            .rename, .color, .delete_empty => {
                if (action == .delete_empty and source.host_count != 0) {
                    self.workspace.status(errorText(error.GroupNotEmpty));
                    return;
                }
                self.view.show(switch (action) {
                    .rename => .rename,
                    .color => .color,
                    else => .delete_empty,
                }, source) catch |err| self.workspace.status(errorText(err));
            },
            .new_host => unreachable,
        }
    }
    fn submit(raw: *anyopaque, request: actions.Request) !actions.Result {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.workspace.shutting_down) return error.WorkspaceClosing;
        const receipt = try actions.apply(self.workspace.allocator, self.workspace.io, std.Io.Dir.cwd(), self.workspace.hosts_path, &self.workspace.registry, request);
        self.workspace.rebuildSidebar() catch self.workspace.status("配置已保存，列表刷新失败");
        return receipt;
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.pending_toggle) |reference| {
            self.pending_toggle = null;
            _ = submit(self, .{ .toggle_collapsed = reference }) catch |err| {
                self.workspace.status(errorText(err));
                return .done;
            };
        }
        return .done;
    }
    fn release(self: *Host) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.workspace.sidebar_bridge.context == @as(?*anyopaque, @ptrCast(self))) self.workspace.sidebar_bridge = .{};
    }
};

pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidGroup => "请输入分组名称。",
        error.DuplicateGroupName => "该分组名称已存在。",
        error.InvalidGroupColor => "请输入 #RRGGBB 格式颜色。",
        error.GroupNotEmpty => "分组中还有主机，无法删除。",
        error.RevisionConflict, error.FileConflict, error.GroupNotFound => "配置已变化，请关闭后重新打开。",
        else => "保存失败，请检查配置后重试。",
    };
}
