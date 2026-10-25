//! Read-only projection of one frozen connection attempt. The host owns the
//! transports and sampling mailboxes; this view never borrows native handles.
const std = @import("std");
const ui = @import("ui");
pub const details = @import("../proto/ssh/connection_details.zig");
const identity = @import("../host/identity.zig");
const realtime = @import("../platform/realtime.zig");
const S = @import("connection_details_styles.zig");
pub const OperationKey = details.OperationKey;
pub const Snapshot = details.ConnectionDetailsSnapshot;
pub const Callbacks = struct {
    context: *anyopaque,
    request_sample: ?*const fn (*anyopaque, OperationKey, ?usize) anyerror!u64 = null,
    cancel_sample: ?*const fn (*anyopaque, OperationKey, u64) anyerror!void = null,
    /// Text is valid for this call only; copy it synchronously or own a copy.
    copy: ?*const fn (*anyopaque, OperationKey, []const u8) anyerror!void = null,
    logs: ?*const fn (*anyopaque, OperationKey) anyerror!void = null,
    edit: ?*const fn (*anyopaque, OperationKey, identity.AssetOwner) anyerror!void = null,
};
pub const Selection = union(enum) { local, hop: usize };
const ActionKind = enum { close, node, copy, fingerprint, logs, edit, close_node, sample };
const ChainState = struct { text: []const u8, online: bool };
const Action = struct {
    view: *View,
    key: OperationKey,
    kind: ActionKind,
    selection: Selection = .local,
    asset_owner: ?identity.AssetOwner = null,
    id: [72]u8 = @splat(0),
    fn click(self: *Action) void {
        if (!self.view.matches(self.key)) return;
        switch (self.kind) {
            .close => self.view.hide(),
            .node => {
                self.view.pending_selection = self.selection;
                self.view.cx.requestRedraw();
            },
            .copy => self.view.copyReport(),
            .fingerprint => self.view.copyFingerprint(),
            .logs => if (self.view.callbacks.logs) |callback| callback(self.view.callbacks.context, self.key) catch {
                self.view.feedback = "无法打开连接日志";
            },
            .edit => if (self.view.callbacks.edit) |callback| if (self.asset_owner) |owner| callback(self.view.callbacks.context, self.key, owner) catch {
                self.view.feedback = "连接配置已变更，请重新打开";
            },
            .close_node => self.view.closeNode(),
            .sample => self.view.pending_sample = true,
        }
        self.view.refreshFeedback();
    }
    fn cleanup(self: *Action) void {
        self.view.cx.allocator.destroy(self);
    }
};

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    material: ?*@import("background_layers.zig").View = null,
    callbacks: Callbacks,
    /// Append once to the window root. Popover content itself is portaled.
    root: *ui.Node = undefined,
    chrome: *ui.Node = undefined,
    open: *ui.Signal(bool),
    source: ?Snapshot = null,
    visible: bool = false,
    expired: bool = false,
    dirty: bool = false,
    content_scope: ?*ui.Scope = null,
    anchor_id: ?u32 = null,
    anchor_rect: ui.widgets.popover.AnchorRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    status_top: f32 = 0,
    sample_request: ?struct { key: OperationKey, id: u64 } = null,
    sample_failure: bool = false,
    pending_sample: bool = false,
    feedback: []const u8 = "",
    feedback_label: ?*ui.Node = null,
    pointer: ?*ui.Node = null,
    source_label: ?*ui.Node = null,
    source_status: ?*ui.Node = null,
    rtt_label: ?*ui.Node = null,
    rows: [details.max_hops + 1]?*ui.Node = @splat(null),
    row_names: [details.max_hops + 1]?*ui.Node = @splat(null),
    row_status: [details.max_hops + 1]?*ui.Node = @splat(null),
    row_count: usize = 0,
    pending_selection: ?Selection = null,
    selection: ?Selection = null,
    node_open: *ui.Signal(bool),
    node_modal: ?ui.widgets.ModalResult = null,
    node_scope: ?*ui.Scope = null,
    node_dirty: bool = false,
    node_fingerprint: ?*ui.Node = null,
    node_algorithm: ?*ui.Node = null,
    node_status: ?*ui.Node = null,
    node_rtt: ?*ui.Node = null,
    rendered_age_second: ?i128 = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try cx.allocator.create(View);
        var registered = false;
        errdefer if (!registered) cx.allocator.destroy(self);
        self.* = .{ .cx = cx, .scope = scope, .callbacks = callbacks, .open = try scope.createSignal(bool, false), .node_open = try scope.createSignal(bool, false) };
        try scope.onCleanup(View, self, cleanup);
        registered = true;
        // Scope children dispose in creation order. Release this view's focus
        // while all Button/Tooltip signals still exist.
        const focus_guard = try scope.childScope();
        const popup = try ui.widgets.Popover(.{ .open = self.open, .trigger = .manual, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchor } }, .position = .top, .width = S.width, .max_width = S.width, .offset = .{ .static = S.anchor_gap }, .viewport_padding = S.margin, .constrain_width_to_viewport = true, .flip = false, .shift_main_axis = false, .on_open_change = cx.on(View, self, openChanged), .enter_transition = .none, .exit_transition = .none }).mount(scope, cx);
        self.scope = popup.scope;
        self.root = popup.wrapper;
        self.chrome = popup.chrome;
        try focus_guard.onCleanup(View, self, releaseFocus);
        self.root.setStyleInline(cx.allocator, S.wrapper());
        self.chrome.meta.ownership.meta.test_id = "connection.details";
        self.chrome.setStyleInline(cx.allocator, S.panel(S.height(1), cx.viewport.width));
        return self;
    }

    /// Both the retained route popover and its lazy node dialog borrow the
    /// same window-owned material, with the popover's scope as their lifetime.
    pub fn setMaterial(self: *View, material: *@import("background_layers.zig").View) !void {
        try material.isolate(self.scope, self.chrome);
        if (self.node_modal) |modal| try material.isolate(self.scope, modal.dialog);
        self.material = material;
    }

    /// Explicit open captures the exact key and trigger. A later active-tab
    /// projection is not permission to replace this read-only target.
    pub fn show(self: *View, snapshot: Snapshot, trigger: *ui.Node, status_top: f32) !void {
        try validate(snapshot);
        const opening = !self.visible;
        if (self.visible and self.source != null and !self.source.?.key.eql(snapshot.key)) self.hide();
        const changed = self.source == null or !self.source.?.key.eql(snapshot.key);
        if (changed) {
            self.source = snapshot;
            self.expired = false;
            self.feedback = "";
            self.sample_failure = false;
            self.selection = null;
            self.pending_selection = null;
            self.dirty = true;
        } else try self.update(snapshot);
        const rect = trigger.globalRect();
        self.anchor_id = trigger.id;
        self.status_top = status_top;
        self.anchor_rect = .{ .x = rect.x, .y = status_top, .w = rect.w, .h = 0 };
        self.visible = true;
        self.open.set(true);
        self.dirty = true;
        try self.flush();
        if ((opening or changed) and !self.expired and self.callbacks.request_sample != null and canSample(snapshot)) {
            const id = self.callbacks.request_sample.?(self.callbacks.context, snapshot.key, null) catch {
                self.sample_failure = true;
                self.dirty = true;
                try self.flush();
                return;
            };
            self.sample_request = .{ .key = snapshot.key, .id = id };
        }
    }

    /// Call from the host's safe UI hook. Snapshot strings are fixed-capacity
    /// value fields, so no network or asset storage can mutate the displayed copy.
    pub fn update(self: *View, snapshot: Snapshot) !void {
        try validate(snapshot);
        const old = self.source orelse return error.DetailsNotVisible;
        if (!old.key.eql(snapshot.key)) return error.DetailsOwnerMismatch;
        if (self.expired) return error.StaleDetails;
        if (snapshot.revision < old.revision) return error.StaleDetails;
        if (snapshot.revision == old.revision) return;
        self.source = snapshot;
        self.dirty = true;
        self.node_dirty = true;
        self.cx.requestRedraw();
    }

    /// The original generation no longer resolves. Keep its frozen identity
    /// and metadata, without asserting that any native resource was released.
    pub fn invalidate(self: *View, key: OperationKey) void {
        if (self.source == null or !self.source.?.key.eql(key) or self.expired) return;
        self.cancelOwnSample();
        self.expired = true;
        self.dirty = true;
        self.node_dirty = true;
        self.cx.requestRedraw();
    }

    /// Button handlers only queue node selection. Rebuild at this safe point.
    pub fn flush(self: *View) !void {
        if (!self.visible) return;
        if (self.pending_sample) {
            self.pending_sample = false;
            if (!self.expired and self.callbacks.request_sample != null and canSample(self.source.?)) {
                self.cancelOwnSample();
                self.sample_failure = false;
                const id = self.callbacks.request_sample.?(self.callbacks.context, self.source.?.key, null) catch blk: {
                    self.sample_failure = true;
                    self.feedback = "链路采样未能启动";
                    break :blk @as(u64, 0);
                };
                if (id != 0) {
                    self.sample_request = .{ .key = self.source.?.key, .id = id };
                    self.feedback = "已请求链路采样";
                }
                self.dirty = true;
            }
        }
        if (self.dirty) {
            self.dirty = false;
            try self.rebuild();
        }
        if (self.pending_selection) |selection| {
            self.pending_selection = null;
            self.selection = selection;
            self.node_dirty = true;
        }
        if (self.node_dirty and self.selection != null) {
            self.node_dirty = false;
            try self.rebuildNode();
        }
        self.positionPointer();
        try self.refreshSampleAge();
    }

    pub fn reanchor(self: *View, status_top: f32) void {
        if (!self.visible) return;
        const trigger = find(self.cx.root orelse return, self.anchor_id orelse return) orelse return;
        if (trigger.style.display == .none) {
            self.hide();
            return;
        }
        const rect = trigger.globalRect();
        const next: ui.widgets.popover.AnchorRect = .{ .x = rect.x, .y = status_top, .w = rect.w, .h = 0 };
        self.status_top = status_top;
        if (!std.meta.eql(next, self.anchor_rect)) {
            self.anchor_rect = next;
            self.chrome.markLayoutDirty();
        }
        self.chrome.setStyle(self.cx.allocator, .height, .{ .px = self.panelHeight() });
        self.chrome.setStyle(self.cx.allocator, .width, S.panel(self.panelHeight(), self.cx.viewport.width).width.?);
        self.positionPointer();
    }
    pub fn isVisible(self: *const View) bool {
        return self.visible;
    }
    pub fn hide(self: *View) void {
        self.dismiss();
        if (self.anchor_id) |id| if (find(self.cx.root orelse return, id)) |node| self.cx.setFocus(node);
    }
    /// A protocol/owner switch closes the old card without returning focus to
    /// its now-inapplicable SSH trigger.
    pub fn dismiss(self: *View) void {
        self.cancelOwnSample();
        self.pending_sample = false;
        self.visible = false;
        self.open.set(false);
        self.closeNode();
    }
    pub fn retheme(self: *View) !void {
        self.dirty = true;
        self.node_dirty = self.selection != null;
        try self.flush();
    }
    fn openChanged(self: *View, value: bool) void {
        if (!value and self.visible) self.hide();
    }
    fn closeNode(self: *View) void {
        self.node_open.set(false);
        self.selection = null;
        self.pending_selection = null;
    }
    fn nodeOpenChanged(self: *View, value: bool) void {
        if (!value) self.closeNode();
    }
    fn matches(self: *const View, key: OperationKey) bool {
        return self.visible and self.source != null and self.source.?.key.eql(key);
    }
    fn cancelOwnSample(self: *View) void {
        const request = self.sample_request orelse return;
        self.sample_request = null;
        if (self.callbacks.cancel_sample) |cancel| cancel(self.callbacks.context, request.key, request.id) catch {};
    }
    fn panelHeight(self: *const View) f32 {
        const natural = S.height(if (self.source) |source| source.hop_count else 1);
        return @min(natural, @max(96, @min(self.cx.viewport.height - S.margin * 2, self.status_top - S.anchor_gap - S.margin)));
    }
    fn positionPointer(self: *View) void {
        const pointer = self.pointer orelse return;
        const w = @min(S.width, @max(0, self.cx.viewport.width - S.margin * 2));
        const center = self.anchor_rect.x + self.anchor_rect.w / 2;
        const left = std.math.clamp(center - w / 2, S.margin, @max(S.margin, self.cx.viewport.width - w - S.margin));
        const p = std.math.clamp(center - left - S.pointer_size / 2, S.margin, @max(S.margin, w - S.margin - S.pointer_size));
        pointer.setStyleInline(self.cx.allocator, S.pointer(p));
    }
    fn anchor(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.visible) if (self.cx.root) |root| if (self.anchor_id) |id| if (find(root, id)) |trigger| {
            const rect = trigger.globalRect();
            if (trigger.isDisplayedInTree() and rect.w > 0) return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 0 };
        };
        return self.anchor_rect;
    }

    fn rebuild(self: *View) !void {
        const snapshot = if (self.source) |*value| value else return;
        clear(self.cx, self.chrome);
        if (self.content_scope) |old| old.dispose();
        self.content_scope = null;
        const scope = try self.scope.childScope();
        self.content_scope = scope;
        self.chrome.setStyleInline(self.cx.allocator, S.panel(self.panelHeight(), self.cx.viewport.width));
        const state: ChainState = if (self.expired) .{ .text = "已过期", .online = false } else chainStatus(snapshot.*);
        const header = try ui.box(self.cx, S.chainHeader(), .{});
        try header.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.network, S.theme.current().accent, S.icon(14)));
        self.source_label = try label(self.cx, header, if (snapshot.source == .@"test") "连接链路 · 最近检测" else "连接链路", S.chainTitle(), .{ .width = .fill(), .height = .{ .px = 20 }, .flex = 1, .min_width = 0 });
        self.source_status = try label(self.cx, header, state.text, S.text(9, 400, 18, false), .{ .width = .{ .px = 40 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
        self.source_status.?.setTextColor(if (state.online) S.theme.current().ok_ink else S.theme.current().fg_2);
        try header.appendChild(self.cx.allocator, try self.iconAction(scope, .close, ui.icons.x, "关闭连接链路", "connection.details.close", false, null, 24, false));
        try self.chrome.appendChild(self.cx.allocator, header);
        try self.chrome.appendChild(self.cx.allocator, try ui.box(self.cx, S.spacer(12), .{}));
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, self.cx);
        scroll.container.setStyleInline(self.cx.allocator, S.scroll());
        scroll.content.setStyleInline(self.cx.allocator, S.chainBody());
        scroll.container.meta.ownership.meta.test_id = "connection.details.body";
        try self.chrome.appendChild(self.cx.allocator, scroll.container);
        self.rows = @splat(null);
        self.row_names = @splat(null);
        self.row_status = @splat(null);
        self.row_count = snapshot.hop_count + 1;
        const nodes = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 0, .flex_shrink = 0 }, .{});
        try self.card(scope, nodes, .local, 0, "本机", "macOS · SSH 客户端", true, "就绪");
        for (snapshot.hops[0..snapshot.hop_count], 0..) |hop, i| {
            const connector = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 22 }, .padding = .{ .left = 18 }, .direction = .row, .align_items = .center, .flex_shrink = 0 }, .{});
            _ = try label(self.cx, connector, "↓ SSH 隧道", S.text(9, 400, 14, false), S.labelBox(14));
            try nodes.appendChild(self.cx.allocator, connector);
            var endpoint_buffer: [1400]u8 = undefined;
            try self.card(scope, nodes, .{ .hop = i }, i + 1, displayName(&hop), try endpoint(&endpoint_buffer, hop.endpoint), !self.expired and hopOnline(snapshot.source, hop.status), if (self.expired) "已过期" else statusText(snapshot.source, hop.status));
        }
        try scroll.content.appendChild(self.cx.allocator, nodes);
        const target = &snapshot.hops[snapshot.hop_count - 1];
        var rtt: [96]u8 = undefined;
        const sample = if (self.expired) null else usableTarget(snapshot.*);
        const rtt_row = try self.info(scroll.content, ui.icons.activity, "端到端延迟", try self.sampleLabel(&rtt, target.*, sample), false);
        self.rtt_label = rtt_row.trailing;
        self.feedback_label = try label(self.cx, scroll.content, self.feedback, S.text(10, 400, 18, false), S.labelBox(18));
        self.feedback_label.?.meta.ownership.meta.test_id = "connection.details.feedback";
        try self.chrome.appendChild(self.cx.allocator, try ui.box(self.cx, S.spacer(14), .{}));
        const footer = try ui.box(self.cx, S.chainFooter(), .{});
        footer.meta.ownership.meta.test_id = "connection.details.footer";
        try footer.appendChild(self.cx.allocator, try self.textAction(scope, .edit, "编辑连接路径", "connection.details.edit", self.callbacks.edit == null or target.endpoint.asset_owner == null, target.endpoint.asset_owner, 96, false));
        try footer.appendChild(self.cx.allocator, try self.iconAction(scope, .copy, ui.icons.copy, "复制链路", "connection.details.copy", self.callbacks.copy == null, null, 24, true));
        try footer.appendChild(self.cx.allocator, try self.iconAction(scope, .logs, ui.icons.get("list").?, "连接日志", "connection.details.logs", self.callbacks.logs == null, null, 24, true));
        try footer.appendChild(self.cx.allocator, try ui.spacer(self.cx));
        try footer.appendChild(self.cx.allocator, try self.textAction(scope, .sample, "测试全链路", "connection.details.sample", self.expired or self.callbacks.request_sample == null or !canSample(snapshot.*), null, 90, true));
        try self.chrome.appendChild(self.cx.allocator, footer);
        self.pointer = try ui.iconTint(self.cx, ui.icons.chevron_down, S.theme.current().fg_2, S.icon(S.pointer_size));
        self.pointer.?.setDisplay(.none);
        try self.chrome.appendChild(self.cx.allocator, self.pointer.?);
    }
    fn textAction(self: *View, scope: *ui.Scope, kind: ActionKind, name: []const u8, test_id: []const u8, disabled: bool, owner: ?identity.AssetOwner, width: f32, primary_action: bool) !*ui.Node {
        const context = try self.action(scope, kind);
        context.asset_owner = owner;
        const button = try ui.widgets.Button(.{ .label = name, .variant = @as(ui.widgets.ButtonVariant, if (primary_action) .primary else .secondary), .base_style = S.chainAction(width, primary_action), .hover_style = .{ .background = if (primary_action) S.theme.current().accent else S.theme.current().hover }, .disabled = disabled, .on_click = self.cx.on(Action, context, Action.click) }).mount(scope, self.cx);
        button.meta.ownership.meta.test_id = test_id;
        return button;
    }

    fn card(self: *View, scope: *ui.Scope, parent: *ui.Node, selection: Selection, index: usize, name: []const u8, address: []const u8, online: bool, state: []const u8) !void {
        const context = try self.action(scope, .node);
        context.selection = selection;
        const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "查看连接节点详情", .base_style = S.card(), .hover_style = S.hover(), .on_click = self.cx.on(Action, context, Action.click) }).mount(scope, self.cx);
        button.meta.ownership.meta.test_id = try std.fmt.bufPrint(&context.id, "connection.details.node.{d}", .{index});
        const content = try ui.box(self.cx, S.cardContent(), .{});
        const asset = switch (selection) {
            .local => ui.icons.get("monitor").?,
            .hop => |hop| if (hop + 1 == self.source.?.hop_count) ui.icons.terminal else ui.icons.get("server").?,
        };
        try content.appendChild(self.cx.allocator, try ui.iconTint(self.cx, asset, if (selection == .local) S.theme.current().fg_2 else S.theme.current().accent, S.icon(16)));
        const identity_box = try ui.box(self.cx, S.cardIdentity(), .{});
        self.row_names[index] = try label(self.cx, identity_box, name, S.text(11, 700, 16, false), S.labelBox(16));
        _ = try label(self.cx, identity_box, address, S.text(9, 400, 14, true), S.labelBox(14));
        try content.appendChild(self.cx.allocator, identity_box);
        const state_node = try label(self.cx, content, state, .{ .font_size = 8, .line_height = 2.25, .text_align = .center, .color = if (online) S.theme.current().ok_ink else S.theme.current().fg_2 }, S.chainBadge(online));
        try content.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.chevron_right, S.theme.current().fg_2, S.icon(12)));
        self.row_status[index] = state_node;
        try button.appendChild(self.cx.allocator, content);
        try parent.appendChild(self.cx.allocator, button);
        self.rows[index] = button;
    }

    const Info = struct { root: *ui.Node, primary: *ui.Node, trailing: *ui.Node };
    fn info(self: *View, parent: *ui.Node, asset: ui.SvgAsset, primary: []const u8, tail: []const u8, online: bool) !Info {
        const row = try ui.box(self.cx, S.info(), .{});
        try row.appendChild(self.cx.allocator, try ui.iconTint(self.cx, asset, if (online) S.theme.current().ok else S.theme.current().fg_2, S.icon(14)));
        const first = try label(self.cx, row, primary, S.infoText(false), S.infoLabel());
        const last = try label(self.cx, row, tail, S.infoText(true), S.trailing());
        if (online) last.setTextColor(S.theme.current().ok);
        try parent.appendChild(self.cx.allocator, row);
        return .{ .root = row, .primary = first, .trailing = last };
    }
    fn action(self: *View, scope: *ui.Scope, kind: ActionKind) !*Action {
        const result = try self.cx.allocator.create(Action);
        result.* = .{ .view = self, .key = self.source.?.key, .kind = kind };
        errdefer self.cx.allocator.destroy(result);
        try scope.onCleanup(Action, result, Action.cleanup);
        return result;
    }
    fn iconAction(self: *View, scope: *ui.Scope, kind: ActionKind, asset: ui.SvgAsset, name: []const u8, id: []const u8, disabled: bool, owner: ?identity.AssetOwner, size: f32, surface: bool) !*ui.Node {
        const context = try self.action(scope, kind);
        context.asset_owner = owner;
        const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = name, .disabled = disabled, .base_style = S.action(size, surface), .hover_style = S.hover(), .on_click = self.cx.on(Action, context, Action.click) }).mount(scope, self.cx);
        button.meta.ownership.meta.test_id = id;
        try button.appendChild(self.cx.allocator, try ui.iconTint(self.cx, asset, if (disabled) S.theme.current().fg_3 else S.theme.current().fg_2, S.icon(16)));
        return iconTooltip(self.cx, scope, button, name);
    }

    fn rebuildNode(self: *View) !void {
        const snapshot = if (self.source) |*value| value else return;
        const selection = self.selection orelse return;
        if (self.node_modal == null) {
            self.node_modal = try ui.widgets.Modal(.{ .open = self.node_open, .width = S.node_width, .max_height = @max(160, self.cx.viewport.height - S.margin * 2), .background = S.theme.current().overlay, .on_open_change = self.cx.on(View, self, nodeOpenChanged) }).mount(self.scope, self.cx);
            if (!self.node_modal.?.portaled) if (self.cx.root) |root| try root.appendChild(self.cx.allocator, self.node_modal.?.overlay);
        }
        const modal = self.node_modal.?;
        if (self.material) |material| try material.isolate(self.scope, modal.dialog);
        clear(self.cx, modal.body);
        if (self.node_scope) |old| old.dispose();
        self.node_scope = null;
        const scope = try self.scope.childScope();
        self.node_scope = scope;
        modal.dialog.setStyleInline(self.cx.allocator, S.nodePanel(self.cx.viewport));
        modal.dialog.meta.ownership.meta.test_id = "connection.details.node-dialog";
        modal.body.setStyleInline(self.cx.allocator, S.stack());
        // ModalPanel supplies 16 px body padding. This panel already owns its
        // Figma header/body insets; retaining that padding clips the last 32 px.
        modal.body.setStyle(self.cx.allocator, .padding, .{});
        modal.body.setStyle(self.cx.allocator, .gap, 0);
        modal.body.setStyle(self.cx.allocator, .height, .fill());
        const header = try ui.box(self.cx, S.nodeHeader(), .{});
        try header.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.get("server").?, S.theme.current().accent, S.icon(18)));
        _ = try label(self.cx, header, "连接节点详情", S.title(), S.titleBox());
        try header.appendChild(self.cx.allocator, try self.iconAction(scope, .close_node, ui.icons.x, "关闭节点详情", "connection.details.node-close", false, null, 22, false));
        try modal.body.appendChild(self.cx.allocator, header);
        const body = try ui.box(self.cx, S.nodeBody(), .{});
        try modal.body.appendChild(self.cx.allocator, body);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, self.cx);
        scroll.container.setStyleInline(self.cx.allocator, S.scroll());
        scroll.content.setStyleInline(self.cx.allocator, S.stack());
        scroll.container.meta.ownership.meta.test_id = "connection.details.node-scroll";
        scroll.content.meta.ownership.meta.test_id = "connection.details.node-content";
        try body.appendChild(self.cx.allocator, scroll.container);
        const content = scroll.content;
        const hop = switch (selection) {
            .local => null,
            .hop => |index| &snapshot.hops[index],
        };
        var address: [1400]u8 = undefined;
        const identity_row = try ui.box(self.cx, S.nodeIdentity(), .{});
        try identity_row.appendChild(self.cx.allocator, try ui.iconTint(self.cx, if (hop != null) ui.icons.get("server").? else ui.icons.get("monitor").?, S.theme.current().accent, S.icon(18)));
        const identity_box = try ui.box(self.cx, S.identity(), .{});
        identity_box.setStyle(self.cx.allocator, .gap, 2);
        _ = try label(self.cx, identity_box, if (hop) |value| displayName(value) else "本机", S.text(14, 500, 21, false), S.labelBox(21));
        _ = try label(self.cx, identity_box, if (hop) |value| try endpoint(&address, value.endpoint) else "本地 SSH 客户端", S.endpoint(), S.labelBox(16));
        try identity_row.appendChild(self.cx.allocator, identity_box);
        try content.appendChild(self.cx.allocator, identity_row);
        const chips = try ui.box(self.cx, S.chips(), .{});
        var role: [96]u8 = undefined;
        const role_text = switch (selection) {
            .local => "本地客户端",
            .hop => |index| try std.fmt.bufPrint(&role, "第 {d} 跳 · {s}", .{ index + 1, if (index + 1 == snapshot.hop_count) "目标" else "跳板" }),
        };
        _ = try self.chip(scope, chips, role_text, false);
        self.node_status = try self.chip(scope, chips, if (self.expired) "已过期" else if (hop) |value| statusText(snapshot.source, value.status) else "本地", !self.expired and if (hop) |value| hopOnline(snapshot.source, value.status) else false);
        try content.appendChild(self.cx.allocator, chips);
        const facts = try ui.box(self.cx, S.facts(), .{});
        var authentication: [192]u8 = undefined;
        var fact: [640]u8 = undefined;
        const metadata: details.Metadata = if (hop) |value| value.metadata else .{};
        const user = if (hop) |value| value.endpoint.user.slice() else "本机";
        const identity_fact = try label(self.cx, facts, try std.fmt.bufPrint(&fact, "身份 {s} · 认证 {s}", .{ unknown(user), try authText(&authentication, metadata.accepted_auth_methods) }), S.paragraph(12, 400, 18, false), S.stack());
        identity_fact.setTextColor(S.theme.current().fg_1);
        self.node_algorithm = try label(self.cx, facts, try std.fmt.bufPrint(&fact, "主机密钥 {s} · 加密 ↑ {s} / ↓ {s}", .{ unknown(metadata.host_key_algorithm.slice()), unknown(metadata.cipher_c2s.slice()), unknown(metadata.cipher_s2c.slice()) }), S.paragraph(11, 400, 16, false), S.stack());
        var rtt: [96]u8 = undefined;
        var time: [96]u8 = undefined;
        const sample = if (self.expired) null else if (hop) |value| usableHop(snapshot.source, value.*) else null;
        self.node_rtt = try label(self.cx, facts, try std.fmt.bufPrint(&fact, "RTT {s} · {s}", .{ if (hop) |value| try self.sampleLabel(&rtt, value.*, sample) else "—", try sampleAge(&time, sample) }), S.paragraph(11, 400, 16, false), S.stack());
        try content.appendChild(self.cx.allocator, facts);
        const fingerprint_box = try ui.box(self.cx, S.fingerprint(), .{});
        _ = try label(self.cx, fingerprint_box, try std.fmt.bufPrint(&fact, "服务器指纹 · {s}", .{unknown(metadata.host_key_algorithm.slice())}), S.text(11, 500, 16, false), S.labelBox(16));
        self.node_fingerprint = try label(self.cx, fingerprint_box, unknown(metadata.fingerprint.slice()), S.paragraph(10, 400, 16, true), S.stack());
        try content.appendChild(self.cx.allocator, fingerprint_box);
        const route = try self.routeText(self.cx.allocator);
        defer self.cx.allocator.free(route);
        _ = try label(self.cx, content, route, S.paragraph(11, 400, 16, false), S.stack());
        // Keep actions outside the scroll viewport so wrapped metadata cannot
        // push the close button below the bounded node dialog.
        const footer = try ui.box(self.cx, S.nodeFooter(), .{});
        try footer.appendChild(self.cx.allocator, try self.iconAction(scope, .fingerprint, ui.icons.copy, "复制指纹", "connection.details.copy-fingerprint", self.callbacks.copy == null or metadata.fingerprint.len == 0, null, 28, true));
        try footer.appendChild(self.cx.allocator, try ui.spacer(self.cx));
        const close_context = try self.action(scope, .close_node);
        const close = try ui.widgets.Button(.{ .label = "关闭详情", .variant = .primary, .base_style = S.primary(), .on_click = self.cx.on(Action, close_context, Action.click) }).mount(scope, self.cx);
        close.meta.ownership.meta.test_id = "connection.details.node-done";
        try footer.appendChild(self.cx.allocator, close);
        try body.appendChild(self.cx.allocator, footer);
        try @import("compact_overlay_layout.zig").mount(self.cx, scope, modal.dialog, scroll.container, scroll.content, 100, S.node_height - 100, null, 0);
        self.node_open.set(true);
        self.cx.requestRedraw();
    }
    fn chip(self: *View, scope: *ui.Scope, parent: *ui.Node, text: []const u8, online: bool) !*ui.Node {
        const node = try ui.widgets.Chip(.{ .label = text, .readonly = true, .size = .sm }).mount(scope, self.cx);
        node.setStyleInline(self.cx.allocator, S.chip(online));
        tintText(node, if (online) S.theme.current().ok else S.theme.current().fg_2);
        try parent.appendChild(self.cx.allocator, node);
        return node;
    }

    pub fn copyReport(self: *View) void {
        const snapshot = self.source orelse return;
        if (!self.visible) return;
        const copy = self.callbacks.copy orelse return;
        const text = self.report(self.cx.allocator) catch {
            self.feedback = "复制失败，请重试";
            return;
        };
        defer self.cx.allocator.free(text);
        copy(self.callbacks.context, snapshot.key, text) catch {
            self.feedback = "复制失败，请重试";
            self.refreshFeedback();
            return;
        };
        self.feedback = "已复制链路";
        self.refreshFeedback();
    }
    pub fn copyFingerprint(self: *View) void {
        const snapshot = self.source orelse return;
        if (!self.visible or self.selection == null or self.selection.? != .hop) return;
        const copy = self.callbacks.copy orelse return;
        const fingerprint = snapshot.hops[self.selection.?.hop].metadata.fingerprint.slice();
        if (fingerprint.len == 0) return;
        copy(self.callbacks.context, snapshot.key, fingerprint) catch {
            self.feedback = "复制失败，请重试";
            self.refreshFeedback();
            return;
        };
        self.feedback = "已复制指纹";
        self.refreshFeedback();
    }
    pub fn report(self: *const View, allocator: std.mem.Allocator) ![]u8 {
        const snapshot = self.source orelse return error.DetailsNotVisible;
        var result: std.Io.Writer.Allocating = .init(allocator);
        errdefer result.deinit();
        const writer = &result.writer;
        try writer.print("通信链路 · {s}\n", .{if (snapshot.source == .@"test") "最近检测" else "当前连接"});
        for (snapshot.hops[0..snapshot.hop_count], 0..) |hop, index| {
            var address: [1400]u8 = undefined;
            try writer.print("{d}. {s} · {s} · {s}\n主机密钥 {s}\n指纹 {s}\n加密 ↑ {s} / ↓ {s}\n", .{ index + 1, displayName(&hop), try endpoint(&address, hop.endpoint), if (self.expired) "已过期" else statusText(snapshot.source, hop.status), unknown(hop.metadata.host_key_algorithm.slice()), unknown(hop.metadata.fingerprint.slice()), unknown(hop.metadata.cipher_c2s.slice()), unknown(hop.metadata.cipher_s2c.slice()) });
        }
        return result.toOwnedSlice();
    }
    fn routeText(self: *const View, allocator: std.mem.Allocator) ![]u8 {
        var result: std.Io.Writer.Allocating = .init(allocator);
        errdefer result.deinit();
        try result.writer.writeAll("Local");
        const snapshot = self.source.?;
        for (snapshot.hops[0..snapshot.hop_count]) |hop| try result.writer.print(" → {s}", .{displayName(&hop)});
        return result.toOwnedSlice();
    }
    fn refreshFeedback(self: *View) void {
        if (self.feedback_label) |node| node.setTextContent(self.cx.allocator, self.feedback) catch {};
        self.cx.requestRedraw();
    }
    fn sampleLabel(self: *const View, buffer: []u8, hop: details.Hop, usable: ?details.Sample) ![]const u8 {
        if (self.expired) return "已过期";
        if (usable) |sample| return std.fmt.bufPrint(buffer, "{d}ms", .{sample.duration_ms.?});
        if (self.source.?.source != .session or hop.status != .online) return "—";
        if (hop.rtt_sample) |sample| return switch (sample.status) {
            .pending => "采样中",
            .unavailable => "不可用",
            .stale => "已过期",
            .ready => if (sample.cleanup != .released) "待核实" else "—",
        };
        return if (self.sample_failure) "不可用" else "—";
    }
    fn refreshSampleAge(self: *View) !void {
        if (!self.node_open.peek() or self.selection == null or self.selection.? != .hop) return;
        const second = @divTrunc(realtime.monotonicNs(), std.time.ns_per_s);
        if (self.rendered_age_second == second) return;
        self.rendered_age_second = second;
        const node = self.node_rtt orelse return;
        const hop = self.source.?.hops[self.selection.?.hop];
        const sample = if (self.expired) null else usableHop(self.source.?.source, hop);
        var rtt: [96]u8 = undefined;
        var age: [96]u8 = undefined;
        var text: [256]u8 = undefined;
        try node.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&text, "RTT {s} · {s}", .{ try self.sampleLabel(&rtt, hop, sample), try sampleAge(&age, sample) }));
    }
    fn cleanup(self: *View) void {
        self.cancelOwnSample();
        self.cx.allocator.destroy(self);
    }
    fn releaseFocus(self: *View) void {
        const focused = self.cx.focus_manager.current_focus orelse return;
        if (focused.isDescendantOf(self.chrome)) {
            self.cx.clearFocus();
            return;
        }
        if (self.node_modal) |modal| if (focused.isDescendantOf(modal.overlay)) self.cx.clearFocus();
    }
};

/// Keep the real Button's keyboard/a11y behavior; the public Tooltip owns hover
/// placement and a focus adapter exposes the same name to keyboard users.
pub fn iconTooltip(cx: *ui.Cx, scope: *ui.Scope, button: *ui.Node, name: []const u8) !*ui.Node {
    const tip = try ui.widgets.Tooltip(.{ .text = name, .background = S.theme.current().overlay, .text_color = S.theme.current().fg_1 }).mount(scope, cx);
    try tip.trigger.appendChild(cx.allocator, button);
    tip.wrapper.setStyleInline(cx.allocator, .{ .flex_shrink = 0 });
    // Scope-aware wrappers remain detachable when the Button's render scope
    // is disposed before this containing scope.
    const focus = try ui.hooks.useFocusState(scope, cx, button);
    try scope.createEffect(.{ .focused = focus.focused, .open = tip.open.? }, struct {
        fn update(value: anytype) void {
            value.open.set(value.focused.get());
        }
    }.update);
    return tip.wrapper;
}

pub fn validate(snapshot: Snapshot) !void {
    if (snapshot.hop_count == 0 or snapshot.hop_count > details.max_hops or snapshot.key.operation_id == 0 or snapshot.key.attempt_id == null or snapshot.key.attempt_id == 0) return error.InvalidDetails;
    if ((snapshot.source == .session and snapshot.key.owner != .session) or (snapshot.source == .@"test" and snapshot.key.owner != .app)) return error.InvalidDetails;
    for (snapshot.hops[0..snapshot.hop_count]) |hop| {
        if (hop.endpoint.host.len > hop.endpoint.host.bytes.len or hop.endpoint.user.len > hop.endpoint.user.bytes.len or hop.endpoint.name.len > hop.endpoint.name.bytes.len or hop.metadata.host_key_algorithm.len > hop.metadata.host_key_algorithm.bytes.len or hop.metadata.fingerprint.len > hop.metadata.fingerprint.bytes.len or hop.metadata.cipher_c2s.len > hop.metadata.cipher_c2s.bytes.len or hop.metadata.cipher_s2c.len > hop.metadata.cipher_s2c.bytes.len) return error.InvalidDetails;
    }
}
fn label(cx: *ui.Cx, parent: *ui.Node, text: []const u8, style: ui.TextStyle, box: ui.BoxStyle) !*ui.Node {
    const node = try ui.text(cx, "", style);
    node.setStyleInline(cx.allocator, box);
    try node.setTextContent(cx.allocator, text);
    try parent.appendChild(cx.allocator, node);
    return node;
}
fn clear(cx: *ui.Cx, parent: *ui.Node) void {
    var index: usize = 0;
    while (index < parent.children.items.len) {
        const child = parent.children.items[index];
        if (@import("background_layers.zig").isSurface(child)) {
            index += 1;
            continue;
        }
        cx.detachChild(parent, child);
        cx.destroyDetached(child);
    }
}
fn find(node: *ui.Node, id: u32) ?*ui.Node {
    if (node.id == id) return node;
    for (node.children.items) |child| if (find(child, id)) |found| return found;
    return null;
}
fn tintText(node: *ui.Node, color: ui.Color) void {
    if (node.getText()) |old| {
        var value = old;
        value.color = color;
        value.font_size = 10.5;
        value.font_weight = 500;
        value.line_height = 16.0 / 10.5;
        node.setText(value);
    }
    for (node.children.items) |child| tintText(child, color);
}
fn unknown(value: []const u8) []const u8 {
    return if (value.len == 0) "未知" else value;
}
fn displayName(hop: *const details.Hop) []const u8 {
    return if (hop.endpoint.name.len != 0) hop.endpoint.name.slice() else unknown(hop.endpoint.host.slice());
}
fn endpoint(buffer: []u8, value: details.Endpoint) ![]const u8 {
    const host = unknown(value.host.slice());
    return if (std.mem.indexOfScalar(u8, host, ':') != null) std.fmt.bufPrint(buffer, "{s}@[{s}]:{d}", .{ unknown(value.user.slice()), host, value.port }) else std.fmt.bufPrint(buffer, "{s}@{s}:{d}", .{ unknown(value.user.slice()), host, value.port });
}
pub fn hopOnline(source: details.Source, status: details.Status) bool {
    return source == .session and status == .online;
}
pub fn statusText(source: details.Source, status: details.Status) []const u8 {
    return switch (status) {
        .not_attempted => "未尝试",
        .negotiating => "连接中",
        .online => if (source == .session) "在线" else "检测中",
        .releasing => "释放中",
        .released => "已释放",
    };
}
fn chainStatus(snapshot: Snapshot) ChainState {
    var all_online = true;
    var all_released = true;
    var releasing = false;
    var any_released = false;
    for (snapshot.hops[0..snapshot.hop_count]) |hop| {
        all_online = all_online and hop.status == .online;
        all_released = all_released and (hop.status == .released or hop.status == .not_attempted);
        releasing = releasing or hop.status == .releasing;
        any_released = any_released or hop.status == .released;
    }
    if (all_online and snapshot.source == .session) return .{ .text = "在线", .online = true };
    return .{ .text = if (releasing) "释放中" else if (all_released and any_released) "已释放" else if (snapshot.source == .@"test") "检测中" else "未连接", .online = false };
}
fn canSample(snapshot: Snapshot) bool {
    if (snapshot.source != .session) return false;
    for (snapshot.hops[0..snapshot.hop_count]) |hop| if (hop.status != .online) return false;
    return true;
}
pub fn usableHop(source: details.Source, hop: details.Hop) ?details.Sample {
    const sample = hop.rtt_sample orelse return null;
    if (!hopOnline(source, hop.status) or sample.status != .ready or sample.cleanup != .released or sample.completed_ns == null or sample.duration_ms == null) return null;
    return sample;
}
pub fn usableTarget(snapshot: Snapshot) ?details.Sample {
    // Target's cumulative route sample is authoritative; never sum hop samples.
    const sample = usableHop(snapshot.source, snapshot.hops[snapshot.hop_count - 1]) orelse return null;
    const target = snapshot.target_rtt_sample orelse return null;
    return if (std.meta.eql(sample, target)) sample else null;
}
fn sampleAge(buffer: []u8, sample: ?details.Sample) ![]const u8 {
    const value = sample orelse return "暂无有效采样";
    const seconds = @divTrunc(@max(0, realtime.monotonicNs() - value.completed_ns.?), std.time.ns_per_s);
    return if (seconds == 0) "刚刚采样" else std.fmt.bufPrint(buffer, "{d} 秒前采样", .{seconds});
}
fn algorithmText(buffer: []u8, metadata: details.Metadata) ![]const u8 {
    if (std.mem.eql(u8, metadata.cipher_c2s.slice(), metadata.cipher_s2c.slice())) return std.fmt.bufPrint(buffer, "{s} · {s}", .{ unknown(metadata.host_key_algorithm.slice()), unknown(metadata.cipher_c2s.slice()) });
    return std.fmt.bufPrint(buffer, "{s} · ↑ {s} / ↓ {s}", .{ unknown(metadata.host_key_algorithm.slice()), unknown(metadata.cipher_c2s.slice()), unknown(metadata.cipher_s2c.slice()) });
}
fn authText(buffer: []u8, methods: @FieldType(details.Metadata, "accepted_auth_methods")) ![]const u8 {
    var result: std.Io.Writer = .fixed(buffer);
    const writer = &result;
    var any = false;
    inline for (.{ .agent, .private_key, .password, .keyboard_interactive }, .{ "Agent 公钥", "公钥", "密码", "交互认证" }) |method, name| {
        if (methods.contains(method)) {
            if (any) try writer.writeAll(" + ");
            try writer.writeAll(name);
            any = true;
        }
    }
    return if (any) result.buffered() else "未知";
}
