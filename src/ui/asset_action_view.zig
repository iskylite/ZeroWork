//! Presentation for saved-asset moves/deletes. Only a matching successful disk
//! commit receipt can enter success; this view never owns or changes sessions.
const std = @import("std");
const ui = @import("ui");
pub const actions = @import("../config/asset_actions.zig");
const identity = @import("../host/identity.zig");
const S = @import("asset_action_styles.zig");
pub const Mode = enum { move, delete };
pub const Step = S.Step;
pub const Group = struct { reference: actions.GroupRef, name: []const u8, host_count: usize = 0 };
pub const Snapshot = struct {
    mode: Mode,
    owner: identity.AssetOwner,
    name: []const u8,
    endpoint: []const u8,
    source_group: ?actions.GroupRef = null,
    source_group_name: []const u8 = "未分组",
    groups: []const Group = &.{},
    open_sessions: usize = 0,
};
pub const Callbacks = struct {
    context: *anyopaque,
    anchor: ?*const fn (*anyopaque, identity.AssetOwner) ?ui.ComputedRect = null,
    completed: ?*const fn (*anyopaque, Mode) void = null,
    submit: *const fn (*anyopaque, actions.Request) anyerror!actions.Result,
    close: ?*const fn (*anyopaque) void = null,
    view_group: ?*const fn (*anyopaque, ?identity.AssetGroupId) void = null,
    view_sessions: ?*const fn (*anyopaque, identity.AssetOwner) void = null,
};
const Option = struct { reference: ?actions.GroupRef, name: []const u8, host_count: usize };
const Owned = struct {
    arena: std.heap.ArenaAllocator,
    value: Snapshot,
    options: []const Option,
    fn init(allocator: std.mem.Allocator, source: Snapshot) !Owned {
        if (@backingInt(source.owner.id) == 0 or source.owner.revision == 0) return error.InvalidIdentity;
        if (source.source_group) |group| try validGroup(group);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var copy = source;
        copy.name = try a.dupe(u8, source.name);
        copy.endpoint = try a.dupe(u8, source.endpoint);
        copy.source_group_name = try a.dupe(u8, if (source.source_group == null) "未分组" else source.source_group_name);
        const groups = try a.alloc(Group, source.groups.len);
        var options: std.ArrayList(Option) = .empty;
        for (source.groups, groups, 0..) |group, *target, index| {
            try validGroup(group.reference);
            for (source.groups[0..index]) |previous| if (previous.reference.id == group.reference.id) return error.DuplicateGroupId;
            target.* = group;
            target.name = try a.dupe(u8, group.name);
            if (source.source_group == null or source.source_group.?.id != group.reference.id) try options.append(a, .{ .reference = group.reference, .name = target.name, .host_count = group.host_count });
        }
        copy.groups = groups;
        if (source.source_group != null) try options.append(a, .{ .reference = null, .name = "未分组", .host_count = 0 });
        return .{ .arena = arena, .value = copy, .options = try options.toOwnedSlice(a) };
    }
};
fn validGroup(group: actions.GroupRef) !void {
    if (@backingInt(group.id) == 0 or group.revision == 0) return error.InvalidIdentity;
}
const GroupRow = struct {
    view: *View,
    index: usize,
    owner: identity.AssetOwner,
    reference: ?actions.GroupRef,
    root: *ui.Node,
    icon: *ui.Node,
    label: *ui.Node,
    button: *ui.Node,
    action_label: *ui.Node,
    button_style: *ui.Signal(ui.BoxStyle),
    button_variant: *ui.Signal(ui.widgets.button.ButtonVariant),
    button_text: *ui.Signal([]const u8),
    group_name: *ui.Signal([]const u8),
    fn choose(self: *GroupRow) void {
        const source = self.view.source orelse return;
        if (!std.meta.eql(source.value.owner, self.owner) or self.index >= source.options.len or !std.meta.eql(source.options[self.index].reference, self.reference)) return;
        self.view.choose(self.index);
    }
    fn paint(self: *GroupRow) void {
        _ = self.view.paint_revision.get();
        const selected = self.view.selected.get() == self.index;
        self.root.setStyleInline(self.view.cx.allocator, S.group(selected, self.view.cx.tokens));
        _ = self.icon.setTint(if (selected) S.theme.current().accent else S.theme.current().fg_2);
        self.label.setTextColor(S.theme.current().fg_1);
        self.button_style.set(S.button(78, 28, selected, false));
        self.button_variant.set(if (selected) .primary else .secondary);
        self.button_text.set(if (selected) "已选择" else "选择");
        self.action_label.setTextColor(S.actionColor(selected, false));
        self.button.behavior.interaction.a11y = .{ .role = .button, .label = self.group_name.peek(), .selected = selected };
    }
};

pub const View = struct {
    anchor_rect: ui.widgets.popover.AnchorRect = .{ .x = 8, .y = 40, .w = 0, .h = 32 },
    cx: *ui.Cx,
    scope: *ui.Scope,
    callbacks: Callbacks,
    root: *ui.Node,
    dialog: *ui.Node,
    body: *ui.Node,
    container: *ui.Node = undefined,
    open: *ui.Signal(bool),
    selected: *ui.Signal(?usize),
    group_count: *ui.Signal(usize),
    paint_revision: *ui.Signal(u64),
    primary_disabled: *ui.Signal(bool),
    secondary_disabled: *ui.Signal(bool),
    primary_style: *ui.Signal(ui.BoxStyle),
    secondary_style: *ui.Signal(ui.BoxStyle),
    primary_variant: *ui.Signal(ui.widgets.button.ButtonVariant),
    primary_text: *ui.Signal([]const u8),
    secondary_text: *ui.Signal([]const u8),
    source: ?Owned = null,
    step: Step = .move_select,
    busy: bool = false,
    failure: ?anyerror = null,
    receipt: ?actions.Result = null,
    title: *ui.Node,
    header_icon: *ui.Node,
    close_button: *ui.Node,
    name: *ui.Node,
    endpoint: *ui.Node,
    identity_icon: *ui.Node,
    caption: *ui.Node,
    groups: *ui.Node,
    pair: *ui.Node,
    from: *ui.Node,
    to: *ui.Node,
    target: *ui.Node,
    target_icon: *ui.Node,
    target_name: *ui.Node,
    target_count: *ui.Node,
    notice: *ui.Node,
    notice_title: *ui.Node,
    notice_detail: *ui.Node,
    footnote: *ui.Node,
    error_box: *ui.Node,
    error_title: *ui.Node,
    error_detail: *ui.Node,
    footer: *ui.Node,
    primary: *ui.Node,
    primary_label: *ui.Node,
    secondary: *ui.Node,
    secondary_label: *ui.Node,

    /// Modal owns its portal placement; callers must not append root again.
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try cx.allocator.create(View);
        var registered = false;
        errdefer if (!registered) cx.allocator.destroy(self);
        self.* = .{
            .cx = cx,
            .scope = scope,
            .callbacks = callbacks,
            .open = try scope.createSignal(bool, false),
            .selected = try scope.createSignal(?usize, null),
            .group_count = try scope.createSignal(usize, 0),
            .paint_revision = try scope.createSignal(u64, 0),
            .primary_disabled = try scope.createSignal(bool, true),
            .secondary_disabled = try scope.createSignal(bool, false),
            .primary_style = try scope.createSignal(ui.BoxStyle, S.button(144, 34, true, false)),
            .secondary_style = try scope.createSignal(ui.BoxStyle, S.button(84, 34, false, false)),
            .primary_variant = try scope.createSignal(ui.widgets.button.ButtonVariant, .primary),
            .primary_text = try scope.createSignal([]const u8, "确认目标分组"),
            .secondary_text = try scope.createSignal([]const u8, "取消"),
            .root = undefined,
            .dialog = undefined,
            .body = undefined,
            .title = undefined,
            .header_icon = undefined,
            .close_button = undefined,
            .name = undefined,
            .endpoint = undefined,
            .identity_icon = undefined,
            .caption = undefined,
            .groups = undefined,
            .pair = undefined,
            .from = undefined,
            .to = undefined,
            .target = undefined,
            .target_icon = undefined,
            .target_name = undefined,
            .target_count = undefined,
            .notice = undefined,
            .notice_title = undefined,
            .notice_detail = undefined,
            .footnote = undefined,
            .error_box = undefined,
            .error_title = undefined,
            .error_detail = undefined,
            .footer = undefined,
            .primary = undefined,
            .primary_label = undefined,
            .secondary = undefined,
            .secondary_label = undefined,
        };
        try scope.onCleanup(View, self, cleanup);
        registered = true;
        try cx.addAfterLayoutHook(self, afterLayout);
        const popup = try ui.widgets.Popover(.{ .open = ui.split(self.open, cx.on(View, self, requestOpen)), .trigger = .manual, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchorRect } }, .position = .right_start, .offset = .{ .static = 6 }, .width = S.width, .max_height = 600, .viewport_padding = 8, .constrain_width_to_viewport = true, .shift_main_axis = true, .consume_outside_click = true, .a11y_role = .dialog }).mount(scope, cx);
        self.root = popup.wrapper;
        self.dialog = popup.chrome;
        self.dialog.setStyleInline(cx.allocator, S.panel(S.height(.move_select)));
        self.dialog.meta.ownership.meta.test_id = "asset.action";
        const content = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .min_height = 0, .padding = .{}, .gap = 0 }, .{});
        self.container = content;
        try popup.content.appendChild(cx.allocator, content);
        if (cx.root) |root| try root.appendChild(cx.allocator, popup.wrapper);
        const header = try ui.box(cx, S.header(), .{});
        self.header_icon = try ui.iconTint(cx, ui.icons.get("folder-input").?, S.theme.current().accent, S.icon(18));
        try header.appendChild(cx.allocator, self.header_icon);
        self.title = try self.label(header, "", 20, S.text(13, 700, false));
        self.title.setStyleInline(cx.allocator, .{ .flex = 1, .min_width = 0 });
        self.close_button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = 16, .a11y_label = "关闭资产操作", .on_click = cx.on(View, self, close), .base_style = S.close() }).mount(scope, cx);
        self.close_button.meta.ownership.meta.test_id = "asset.action.close";
        try header.appendChild(cx.allocator, self.close_button);
        try content.appendChild(cx.allocator, header);
        self.body = try ui.box(cx, S.body(), .{});
        try content.appendChild(cx.allocator, self.body);
        const identity_row = try ui.box(cx, S.row(40, 12), .{});
        self.identity_icon = try ui.iconTint(cx, ui.icons.server, S.theme.current().accent, S.icon(20));
        try identity_row.appendChild(cx.allocator, self.identity_icon);
        const identity_text = try ui.box(cx, S.identityText(), .{});
        self.name = try self.label(identity_text, "", 21, S.text(14, 500, false));
        self.name.meta.ownership.meta.test_id = "asset.action.name";
        self.endpoint = try self.label(identity_text, "", 16, S.text(10.5, 400, true));
        try identity_row.appendChild(cx.allocator, identity_text);
        try self.body.appendChild(cx.allocator, identity_row);
        self.caption = try self.label(self.body, "", 16, S.text(11, 400, false));
        const list = try ui.widgets.VirtualList(.{ .item_count = self.group_count, .item_height = S.item_height, .height = S.list_height, .overscan = 1 }).rows(self, renderGroup).viewMount(scope, cx);
        self.groups = list.root.?;
        self.groups.setStyleInline(cx.allocator, S.groupList());
        self.groups.meta.ownership.meta.test_id = "asset.action.groups";
        try self.body.appendChild(cx.allocator, self.groups);
        self.pair = try ui.box(cx, S.pair(), .{});
        self.from = try self.label(self.pair, "", 18, S.text(12, 400, false));
        self.to = try self.label(self.pair, "", 18, S.text(12, 500, false));
        try self.body.appendChild(cx.allocator, self.pair);
        self.target = try ui.box(cx, S.target(), .{});
        self.target_icon = try ui.iconTint(cx, ui.icons.folder, S.theme.current().accent, S.icon(18));
        try self.target.appendChild(cx.allocator, self.target_icon);
        self.target_name = try self.label(self.target, "", 18, S.text(12, 500, false));
        self.target_name.setStyleInline(cx.allocator, .{ .flex = 1, .min_width = 0 });
        self.target_count = try self.label(self.target, "", 16, S.text(11, 400, false));
        self.target_count.setStyleInline(cx.allocator, .{ .width = .{ .px = 94 } });
        try self.body.appendChild(cx.allocator, self.target);
        self.notice = try ui.box(cx, S.notice(.move_confirm), .{});
        self.notice_title = try self.label(self.notice, "", 18, S.text(12, 500, false));
        self.notice_detail = try self.label(self.notice, "", 16, S.paragraph());
        try self.body.appendChild(cx.allocator, self.notice);
        self.footnote = try self.label(self.body, "", 16, S.paragraph());
        self.error_box = try ui.box(cx, S.errorBox(), .{});
        self.error_title = try self.label(self.error_box, "", 16, S.text(11, 500, false));
        self.error_detail = try self.label(self.error_box, "", 16, S.text(10.5, 400, false));
        try self.body.appendChild(cx.allocator, self.error_box);
        self.footer = try ui.box(cx, S.footer(), .{});
        self.secondary = try ui.widgets.Button(.{ .label = self.secondary_text, .variant = .secondary, .disabled = self.secondary_disabled, .on_click = cx.on(View, self, secondaryAction), .base_style = self.secondary_style }).mount(scope, cx);
        self.secondary_label = findText(self.secondary).?;
        self.secondary.meta.ownership.meta.test_id = "asset.action.secondary";
        try self.footer.appendChild(cx.allocator, self.secondary);
        self.primary = try ui.widgets.Button(.{ .label = self.primary_text, .variant = self.primary_variant, .disabled = self.primary_disabled, .on_click = cx.on(View, self, primaryAction), .base_style = self.primary_style }).mount(scope, cx);
        self.primary_label = findText(self.primary).?;
        self.primary.meta.ownership.meta.test_id = "asset.action.primary";
        try self.footer.appendChild(cx.allocator, self.primary);
        try self.body.appendChild(cx.allocator, self.footer);
        return self;
    }
    fn label(self: *View, parent: *ui.Node, value: []const u8, h: f32, style: ui.TextStyle) !*ui.Node {
        const node = try ui.text(self.cx, value, style);
        node.setStyleInline(self.cx.allocator, S.label(h));
        try parent.appendChild(self.cx.allocator, node);
        return node;
    }
    fn setFmt(self: *View, node: *ui.Node, comptime format: []const u8, values: anytype) !void {
        const text = try std.fmt.allocPrint(self.cx.allocator, format, values);
        defer self.cx.allocator.free(text);
        try node.setTextContent(self.cx.allocator, text);
    }
    fn renderGroup(self: *View, index: usize, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        const source = self.source orelse return error.NoAssetAction;
        const option = source.options[index];
        const root = try ui.box(cx, S.group(self.selected.peek() == index, cx.tokens), .{});
        const icon = try ui.iconTint(cx, ui.icons.folder, S.theme.current().fg_2, S.icon(16));
        try root.appendChild(cx.allocator, icon);
        const label_node = try ui.text(cx, "", S.text(12, 400, false));
        try label_node.setTextContent(cx.allocator, option.name);
        label_node.setStyleInline(cx.allocator, S.groupLabel());
        try root.appendChild(cx.allocator, label_node);
        const state = try scope.createState(GroupRow, .{
            .view = self,
            .index = index,
            .owner = source.value.owner,
            .reference = option.reference,
            .root = root,
            .icon = icon,
            .label = label_node,
            .button = undefined,
            .action_label = undefined,
            .button_style = try scope.createSignal(ui.BoxStyle, S.button(78, 28, false, false)),
            .button_variant = try scope.createSignal(ui.widgets.button.ButtonVariant, .secondary),
            .button_text = try scope.createSignal([]const u8, "选择"),
            .group_name = try scope.createText(option.name, .{}),
        });
        const button = try ui.widgets.Button(.{ .label = state.button_text, .variant = state.button_variant, .a11y_label = state.group_name, .on_click = cx.on(GroupRow, state, GroupRow.choose), .base_style = state.button_style }).mount(scope, cx);
        button.meta.ownership.meta.test_id = "asset.action.group.choose";
        state.button = button;
        state.action_label = findText(button).?;
        try root.appendChild(cx.allocator, button);
        try scope.createEffect(state, GroupRow.paint);
        return root;
    }
    fn anchorRect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.source) |source| if (self.callbacks.anchor) |resolve| if (resolve(self.callbacks.context, source.value.owner)) |rect| {
            self.anchor_rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
        };
        return self.anchor_rect;
    }
    pub fn show(self: *View, snapshot: Snapshot) !void {
        if (self.isVisible()) return error.AssetActionAlreadyOpen;
        var next = try Owned.init(self.cx.allocator, snapshot);
        var adopted = false;
        errdefer if (!adopted) next.arena.deinit();
        self.group_count.set(0);
        if (self.source) |*old| old.arena.deinit();
        self.source = next;
        adopted = true;
        self.failure = null;
        self.receipt = null;
        self.busy = false;
        self.step = if (snapshot.mode == .move) .move_select else .delete_confirm;
        self.selected.set(if (snapshot.mode == .move and next.options.len != 0) 0 else null);
        self.group_count.set(if (snapshot.mode == .move) next.options.len else 0);
        try self.name.setTextContent(self.cx.allocator, next.value.name);
        try self.endpoint.setTextContent(self.cx.allocator, next.value.endpoint);
        try self.refresh();
        self.open.set(true);
        self.cx.setFocus(self.secondary);
        self.cx.requestRedraw();
    }
    pub fn hide(self: *View) void {
        self.open.set(false);
        self.cx.requestRedraw();
    }
    pub fn isVisible(self: *const View) bool {
        return self.open.peek();
    }
    pub fn choose(self: *View, index: usize) void {
        const source = self.source orelse return;
        if (!self.isVisible() or self.busy or self.step != .move_select or index >= source.options.len) return;
        self.selected.set(index);
        self.failure = null;
        self.refresh() catch {};
    }
    pub fn primaryAction(self: *View) void {
        if (!self.isVisible() or self.busy or self.primary_disabled.peek()) return;
        const source = self.source orelse return;
        switch (self.step) {
            .move_select => {
                const option = source.options[self.selected.peek() orelse return];
                self.commit(.{ .move = .{ .owner = source.value.owner, .source_group = source.value.source_group, .destination = option.reference } });
            },
            .move_confirm => {
                const option = source.options[self.selected.peek() orelse return];
                self.commit(.{ .move = .{ .owner = source.value.owner, .source_group = source.value.source_group, .destination = option.reference } });
            },
            .delete_confirm => self.commit(.{ .delete = .{ .owner = source.value.owner } }),
            .move_success => {
                const target = source.options[self.selected.peek() orelse return].reference;
                self.hide();
                if (self.callbacks.view_group) |callback| callback(self.callbacks.context, if (target) |group| group.id else null);
            },
            .delete_success => self.close(),
        }
    }
    pub fn secondaryAction(self: *View) void {
        if (!self.isVisible() or self.busy or self.secondary_disabled.peek()) return;
        const source = self.source orelse return;
        if (self.step == .delete_success) {
            self.hide();
            if (self.callbacks.view_sessions) |callback| callback(self.callbacks.context, source.value.owner);
        } else self.close();
    }
    fn commit(self: *View, request: actions.Request) void {
        self.busy = true;
        self.primary_disabled.set(true);
        self.secondary_disabled.set(true);
        self.failure = null;
        const receipt = self.callbacks.submit(self.callbacks.context, request) catch |err| {
            self.busy = false;
            self.failure = err;
            self.refresh() catch {};
            return;
        };
        self.busy = false;
        const owner = self.source.?.value.owner;
        if (receipt.kind != std.meta.activeTag(request) or !std.meta.eql(receipt.source_owner, owner) or receipt.commit.revision <= receipt.commit.previous_revision or
            (request == .delete and (receipt.owner != null or receipt.index != null)) or
            (request == .move and (receipt.owner == null or receipt.index == null or receipt.owner.?.id != owner.id or receipt.owner.?.revision <= owner.revision)))
        {
            self.failure = error.CommitReceiptMismatch;
        } else {
            self.receipt = receipt;
            self.step = if (request == .move) .move_success else .delete_success;
            self.refresh() catch {};
            self.hide();
            if (self.callbacks.completed) |callback| callback(self.callbacks.context, self.source.?.value.mode);
            return;
        }
        self.refresh() catch {};
        self.cx.setFocus(self.secondary);
    }
    pub fn close(self: *View) void {
        if (!self.isVisible() or self.busy) return;
        self.hide();
        if (self.callbacks.close) |callback| callback(self.callbacks.context);
    }
    fn requestOpen(self: *View, value: bool) void {
        if (!value) self.close();
    }
    pub fn retheme(self: *View) !void {
        try self.refresh();
        self.paint_revision.set(self.paint_revision.peek() +% 1);
    }
    fn refresh(self: *View) !void {
        const source = self.source orelse return;
        const snapshot = source.value;
        const a = self.cx.allocator;
        const option = if (self.selected.peek()) |index| if (index < source.options.len) source.options[index] else null else null;
        const success = self.step == .move_success or self.step == .delete_success;
        const panel_height = S.height(self.step) + if (self.failure != null) S.error_height + 10 else @as(f32, 0);
        self.dialog.setStyleInline(a, S.panel(panel_height));
        self.container.setStyle(a, .height, .{ .px = panel_height });
        try self.title.setTextContent(a, switch (self.step) {
            .move_select => "移动主机 · 选择分组",
            .move_confirm => "移动主机 · 确认",
            .move_success => "主机已移动",
            .delete_confirm => "删除主机配置",
            .delete_success => "主机配置已删除",
        });
        _ = self.header_icon.setTint(S.theme.current().accent);
        _ = self.identity_icon.setTint(S.theme.current().accent);
        if (self.header_icon.getIcon()) |old| {
            var icon = old;
            const asset = if (snapshot.mode == .delete) ui.icons.get("trash-2").? else ui.icons.get("folder-input").?;
            icon.icon_id = asset.icon_id.?;
            icon.rep = asset.pickRep(18).?;
            self.header_icon.setIcon(icon);
        }
        self.title.setTextColor(S.theme.current().fg_1);
        self.name.setTextColor(S.theme.current().fg_1);
        self.endpoint.setTextColor(S.theme.current().fg_2);
        self.caption.setDisplay(.none);
        if (self.step == .delete_confirm) try self.setFmt(self.caption, "资产分组 {s} · 已打开 {d} 个会话", .{ snapshot.source_group_name, snapshot.open_sessions }) else try self.setFmt(self.caption, "当前分组 {s} · 选择目标分组", .{snapshot.source_group_name});
        self.caption.setTextColor(S.theme.current().fg_2);
        self.groups.setDisplay(if (self.step == .move_select) .flex else .none);
        self.pair.setDisplay(if (self.step == .move_confirm) .flex else .none);
        self.pair.setBackground(S.theme.popupAction());
        try self.setFmt(self.from, "来源分组  {s}", .{snapshot.source_group_name});
        try self.setFmt(self.to, "目标分组  {s}", .{if (option) |value| value.name else "未选择"});
        self.from.setTextColor(S.theme.current().fg_2);
        self.to.setTextColor(S.theme.current().fg_1);
        self.target.setDisplay(if (self.step == .move_success) .flex else .none);
        self.target.setBackground(S.theme.popupAction());
        _ = self.target_icon.setTint(S.theme.current().accent);
        try self.target_name.setTextContent(a, if (option) |value| value.name else "未选择");
        try self.setFmt(self.target_count, "{d} 台主机", .{if (option) |value| value.host_count +| 1 else 0});
        self.target_name.setTextColor(S.theme.current().fg_1);
        self.target_count.setTextColor(S.theme.current().fg_2);
        self.notice.setDisplay(if (self.step == .move_select) .none else .flex);
        self.notice.setStyleInline(a, S.notice(self.step));
        self.notice_detail.setStyleInline(a, S.label(if (self.step == .delete_confirm) 32 else 16));
        switch (self.step) {
            .move_confirm => try self.setFmt(self.notice_title, "移动 {s}？", .{snapshot.name}),
            .delete_confirm => try self.setFmt(self.notice_title, "删除 {s} 的主机配置？", .{snapshot.name}),
            .move_success => try self.notice_title.setTextContent(a, "主机已移动"),
            .delete_success => try self.notice_title.setTextContent(a, "主机配置已删除"),
            .move_select => try self.notice_title.setTextContent(a, ""),
        }
        switch (self.step) {
            .move_confirm => try self.notice_detail.setTextContent(a, "连接配置与跳板顺序保持不变，现有会话继续运行。"),
            .delete_confirm => try self.notice_detail.setTextContent(a, "仅删除保存的连接配置，已打开的会话继续运行。"),
            .move_success => try self.setFmt(self.notice_detail, "{s} 已从 {s} 移入 {s}，现有会话继续运行。", .{ snapshot.name, snapshot.source_group_name, if (option) |value| value.name else "未选择" }),
            .delete_success => try self.setFmt(self.notice_detail, "{s} 已从 {s} 移除。已打开的会话继续运行。", .{ snapshot.name, snapshot.source_group_name }),
            .move_select => try self.notice_detail.setTextContent(a, ""),
        }
        self.notice_title.setDisplay(.none);
        self.notice_title.setTextColor(S.noticeColor(self.step, true));
        self.notice_detail.setTextColor(S.theme.current().fg_2);
        self.footnote.setDisplay(if (self.step == .move_select) .flex else .none);
        self.footnote.setStyleInline(a, S.label(32));
        try self.footnote.setTextContent(a, switch (self.step) {
            .move_select => "移动仅改变主机的资产归属，已打开的会话会继续运行。",
            .delete_confirm => "本操作只删除本地主机配置。断开会话需要单独确认。",
            .delete_success => "若需断开已有会话，请在对应页签中使用断开并关闭。",
            else => "",
        });
        self.footnote.setTextColor(S.theme.current().fg_2);
        self.error_box.setDisplay(if (self.failure != null) .flex else .none);
        self.error_box.setBackground(S.theme.current().danger.withAlpha(23));
        try self.error_title.setTextContent(a, if (self.failure) |err| if (err == error.CommitReceiptMismatch) "保存结果无法核实，请重新打开列表核对" else if (err == error.RevisionConflict or err == error.FileConflict) "配置已变更，请关闭后重新操作" else "保存失败，配置尚未更改" else "");
        try self.error_detail.setTextContent(a, if (self.failure) |err| @errorName(err) else "");
        self.error_title.setTextColor(S.theme.current().danger_ink);
        self.error_detail.setTextColor(S.theme.current().fg_2);
        const primary_text: []const u8 = switch (self.step) {
            .move_select => "移动主机",
            .move_confirm => "移动主机",
            .move_success => "查看目标分组",
            .delete_confirm => "删除主机配置",
            .delete_success => "返回主机列表",
        };
        const secondary_text: []const u8 = switch (self.step) {
            .move_success => "完成",
            .delete_confirm => "保留主机",
            .delete_success => "查看现有会话",
            else => "取消",
        };
        self.primary_disabled.set(self.busy or (self.failure != null and self.failure.? == error.CommitReceiptMismatch) or (!success and snapshot.mode == .move and option == null) or (self.step == .move_success and self.callbacks.view_group == null));
        self.secondary_disabled.set(self.busy or (self.step == .delete_success and (self.callbacks.view_sessions == null or snapshot.open_sessions == 0)));
        self.primary_style.set(S.button(S.primaryWidth(self.step), 30, true, self.step == .delete_confirm));
        self.secondary_style.set(S.button(S.secondaryWidth(self.step), 30, false, false));
        self.primary_variant.set(if (self.step == .delete_confirm) .danger else .primary);
        self.primary_text.set(primary_text);
        self.secondary_text.set(secondary_text);
        self.primary_label.setTextColor(S.actionColor(true, self.primary_disabled.peek()));
        self.secondary_label.setTextColor(S.actionColor(false, self.secondary_disabled.peek()));
        self.primary.behavior.interaction.a11y = .{ .role = .button, .label = self.primary_label.getText().?.content, .disabled = self.primary_disabled.peek() };
        self.secondary.behavior.interaction.a11y = .{ .role = .button, .label = self.secondary_label.getText().?.content, .disabled = self.secondary_disabled.peek() };
        self.cx.requestRedraw();
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.isVisible() or self.busy) return .done;
        if (self.callbacks.anchor) |resolve| {
            const rect = resolve(self.callbacks.context, self.source.?.value.owner) orelse {
                self.close();
                return .done;
            };
            if (rect.w <= 0 or rect.h <= 0 or rect.y + rect.h <= 0 or rect.y >= self.cx.viewport.height) self.close();
        }
        return .done;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.source) |*source| source.arena.deinit();
        self.cx.allocator.destroy(self);
    }
};
fn findText(node: *ui.Node) ?*ui.Node {
    if (node.getText() != null) return node;
    for (node.children.items) |child| if (findText(child)) |found| return found;
    return null;
}
