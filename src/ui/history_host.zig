//! Global history catalogue. Events only capture work; safe frame hooks replace
//! rows and mount completed documents. No action borrows the active connection.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");
const catalog = @import("history_list.zig");
const archive_mod = @import("../vt/session_archive.zig");
const loading = @import("history_archive.zig");
const S = @import("history_styles.zig");
const Action = @import("history_row.zig").Action;

pub const Host = struct {
    allocator: std.mem.Allocator,
    cx: *ui.Cx,
    scope: *ui.Scope,
    workspace: ?*@import("workspace.zig").Workspace = null,
    panel: *ui.Node,
    card: *ui.Node,
    list: *ui.Node,
    count: *ui.Node,
    message: *ui.Node,
    message_warning: bool = false,
    query_input: ui.widgets.input.InputResult,
    scroll: ui.widgets.ScrollAreaResult,
    close_button: *ui.Node,
    close_hint: *ui.Signal(bool),
    trigger: ?*ui.Node = null,
    filter_buttons: [3]*ui.Node,
    retry_button: *ui.Node,
    archive: archive_mod.Archive,
    archive_dir_owned: bool = true,
    model: catalog.Model,
    row_scope: ?*ui.Scope = null,
    rows: std.ArrayList(*ui.Node) = .empty,
    row_indices: std.ArrayList(usize) = .empty,
    colors: theme.Colors,
    generation: u64 = 0,
    source: ?catalog.SourceFilter = null,
    refresh_job: ?*loading.CatalogJob = null,
    open_job: ?*loading.Job = null,
    needs_rebuild: bool = false,
    restore_focus: ?ui.hit.NodeHandle = null,
    selected: ?usize = null,
    pending_focus: bool = false,
    viewport_width: f32 = 0,
    viewport_height: f32 = 0,
    pending_reload: bool = false,
    catalog_failure: bool = false,
    delete_job: ?*loading.DeleteJob = null,
    confirmation: *ui.Node,
    confirmation_open: *ui.Signal(bool),
    confirmation_anchor: ui.ComputedRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    clear_button: *ui.Node,
    delete_buttons: std.ArrayList(*ui.Node) = .empty,
    confirmation_text: *ui.Node,
    cancel_button: *ui.Node,
    clear_disabled: *ui.Signal(bool),
    actions_disabled: *ui.Signal(bool),

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, directory: []const u8) !*Host {
        try std.Io.Dir.cwd().createDirPath(cx.io, directory);
        const dir = try std.Io.Dir.cwd().openDir(cx.io, directory, .{});
        errdefer dir.close(cx.io);
        const self = try cx.allocator.create(Host);
        errdefer cx.allocator.destroy(self);
        const panel = try ui.box(cx, .{ .position = .absolute, .width = .fill(), .height = .fill(), .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } }, .z_index = 500, .hit_behavior = .@"opaque" }, .{});
        panel.setDisplay(.none);
        panel.behavior.interaction.focus_scope = .{ .trap = true };
        const card = try ui.box(cx, S.card(), .{});
        card.meta.ownership.meta.test_id = "history.panel";
        card.setPointerDownFocus(.preserve);
        @import("floating_input.zig").protect(cx, panel);
        @import("floating_input.zig").protect(cx, card);
        try panel.appendChild(cx.allocator, card);
        const head = try ui.box(cx, S.header(), .{});
        try card.appendChild(cx.allocator, head);
        try head.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.history, theme.current().accent, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 }));
        try head.appendChild(cx.allocator, try ui.text(cx, "回看日志", S.text(14, 600, false)));
        try head.appendChild(cx.allocator, try ui.spacer(cx));
        const count = try ui.text(cx, "正在读取…", S.text(12, 400, true));
        count.meta.ownership.meta.test_id = "history.count";
        try head.appendChild(cx.allocator, count);
        const close_button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = @as(f32, 16), .a11y_label = "关闭历史列表", .base_style = S.close(), .on_click = cx.on(Host, self, close) }).mount(scope, cx);
        close_button.meta.ownership.meta.test_id = "history.close";
        const close_hint = try @import("control_hint.zig").mount(cx, scope, close_button, "关闭历史列表（Esc）", .{ .id = "history.close.tooltip", .layout = .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .flex_shrink = 0 } });
        try head.appendChild(cx.allocator, close_hint.wrapper);
        const query_input = try ui.widgets.Input(.{ .placeholder = "搜索主机、用户或地址", .leading_icon_asset = ui.icons.search, .on_change = cx.on(Host, self, queryChanged), .on_submit = cx.on(Host, self, submit) }).mountResult(scope, cx);
        theme.styleInput(query_input);
        query_input.state.font_size = 13;
        query_input.state.line_height = 19.5;
        query_input.state.char_width = 7.8;
        query_input.state.dirty = true;
        if (query_input.state.text_display_node) |text| if (text.getText()) |current| {
            var next = current;
            next.font_size = 13;
            next.line_height = 1.5;
            text.setText(next);
        };
        query_input.node.meta.ownership.meta.test_id = "history.query";
        query_input.input_container.meta.ownership.meta.test_id = "history.search";
        query_input.node.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 36 }, .flex_shrink = 0 });
        query_input.input_container.setStyleInline(cx.allocator, .{ .height = .{ .px = 36 }, .background = theme.popupInset(), .border = .{ .width = 0, .radius = 8 } });
        try card.appendChild(cx.allocator, query_input.node);
        const filters = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 28 }, .margin = .{ .top = 10 }, .direction = .row, .align_items = .center, .gap = 4, .flex_shrink = 0 }, .{});
        try card.appendChild(cx.allocator, filters);
        var filter_buttons: [3]*ui.Node = undefined;
        inline for (.{ "全部", "SSH", "本地" }, 0..) |label, i| {
            const button = try ui.widgets.Button(.{ .label = label, .variant = .ghost, .size = .sm, .base_style = ui.BoxStyle{ .height = .{ .px = 28 }, .padding = .{ .left = 10, .right = 10 }, .font_size = 12, .border = .{ .radius = 6 }, .flex_shrink = 0 }, .on_click = cx.on(Host, self, switch (i) {
                0 => all,
                1 => ssh,
                else => local,
            }) }).mount(scope, cx);
            button.meta.ownership.meta.test_id = switch (i) {
                0 => "history.filter.all",
                1 => "history.filter.ssh",
                else => "history.filter.local",
            };
            filter_buttons[i] = button;
            try filters.appendChild(cx.allocator, button);
        }
        try filters.appendChild(cx.allocator, try ui.spacer(cx));
        const clear_disabled = try scope.createSignal(bool, true);
        const actions_disabled = try scope.createSignal(bool, false);
        const clear = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.get("list-x").?, .icon_size = 16, .a11y_label = "清空历史列表", .variant = .ghost, .size = .sm, .disabled = clear_disabled, .base_style = S.rowAction(), .on_click = cx.on(Host, self, clearRecords) }).mount(scope, cx);
        clear.meta.ownership.meta.test_id = "history.clear";
        const clear_hint = try @import("control_hint.zig").mount(cx, scope, clear, "清空历史列表（需确认）", .{ .id = "history.clear.tooltip" });
        try filters.appendChild(cx.allocator, clear_hint.wrapper);
        const scroll = try ui.widgets.ScrollArea(.{ .height = 200, .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        scroll.container.meta.ownership.meta.test_id = "history.viewport";
        scroll.container.style.margin.top = 10;
        scroll.container.style.flex_shrink = 0;
        const list = try ui.box(cx, S.list(), .{});
        try scroll.content.appendChild(cx.allocator, list);
        try card.appendChild(cx.allocator, scroll.container);
        var message_style = S.text(12, 400, true);
        message_style.wrap = .word;
        const message = try ui.text(cx, "", message_style);
        message.meta.ownership.meta.test_id = "history.message";
        message.setStyleInline(cx.allocator, .{ .width = .fill(), .margin = .{ .top = 8 }, .flex_shrink = 0 });
        message.setDisplay(.none);
        try card.appendChild(cx.allocator, message);
        const retry_button = try ui.widgets.Button(.{ .label = "重新读取", .variant = .secondary, .size = .sm, .on_click = cx.on(Host, self, retry) }).mount(scope, cx);
        retry_button.meta.ownership.meta.test_id = "history.retry";
        retry_button.setDisplay(.none);
        try card.appendChild(cx.allocator, retry_button);
        const confirmation_open = try scope.createSignal(bool, false);
        const popup = try ui.widgets.Popover(.{ .open = confirmation_open, .trigger = .manual, .anchor = .{ .virtual = .{ .ctx = self, .getRect = confirmationAnchor } }, .position = .bottom_end, .offset = .{ .static = 6 }, .width = 288, .max_width = 288, .constrain_width_to_viewport = true, .viewport_padding = 12, .flip = true, .shift_main_axis = true, .size_policy = .fit_content, .close_on_outside_click = true, .consume_outside_click = true, .close_on_escape = true, .on_open_change = cx.on(Host, self, confirmationChanged), .enter_transition = .none, .exit_transition = .none, .a11y_role = .dialog }).mount(scope, cx);
        popup.wrapper.setDisplay(.none);
        try panel.appendChild(cx.allocator, popup.wrapper);
        const confirmation = popup.chrome;
        confirmation.setStyleInline(cx.allocator, S.confirmationChrome(cx.tokens));
        confirmation.meta.per_frame.hooks.on_theme = confirmationTheme;
        const confirmation_body = try ui.box(cx, S.confirmationBody(), .{});
        try popup.content.appendChild(cx.allocator, confirmation_body);
        confirmation.meta.ownership.meta.test_id = "history.confirmation";
        var confirmation_style = S.text(13, 500, false);
        confirmation_style.wrap = .word;
        const confirmation_text = try ui.text(cx, "", confirmation_style);
        confirmation_text.setStyleInline(cx.allocator, .{ .width = .fill() });
        try confirmation_body.appendChild(cx.allocator, confirmation_text);
        try confirmation_body.appendChild(cx.allocator, try ui.text(cx, "录制文件也会删除，无法撤销。", S.text(12, 400, true)));
        const confirmation_actions = try ui.box(cx, S.actions(), .{});
        try confirmation_actions.appendChild(cx.allocator, try ui.spacer(cx));
        const cancel_button = try ui.widgets.Button(.{ .label = "取消", .variant = .secondary, .size = .sm, .base_style = actionStyle(), .on_click = cx.on(Host, self, cancelDelete) }).mount(scope, cx);
        cancel_button.meta.ownership.meta.test_id = "history.delete.cancel";
        try confirmation_actions.appendChild(cx.allocator, cancel_button);
        const confirm_button = try ui.widgets.Button(.{ .label = "确认删除", .variant = .danger, .size = .sm, .base_style = actionStyle(), .on_click = cx.on(Host, self, confirmDelete) }).mount(scope, cx);
        confirm_button.meta.ownership.meta.test_id = "history.delete.confirm";
        try confirmation_actions.appendChild(cx.allocator, confirm_button);
        try confirmation_body.appendChild(cx.allocator, confirmation_actions);
        self.* = .{ .allocator = cx.allocator, .cx = cx, .scope = scope, .panel = panel, .card = card, .list = list, .count = count, .message = message, .query_input = query_input, .scroll = scroll, .close_button = close_button, .close_hint = close_hint.open.?, .filter_buttons = filter_buttons, .retry_button = retry_button, .archive = .{ .allocator = cx.allocator, .io = cx.io, .dir = dir }, .model = undefined, .colors = theme.current(), .confirmation = confirmation, .confirmation_open = confirmation_open, .clear_button = clear, .confirmation_text = confirmation_text, .cancel_button = cancel_button, .clear_disabled = clear_disabled, .actions_disabled = actions_disabled };
        self.model = catalog.Model.init(cx.allocator, &self.archive);
        panel.behavior.events.event_context = self;
        panel.behavior.events.on_event_capture = onPanelEvent;
        try cx.addAfterLayoutHook(self, frame);
        try scope.onCleanup(Host, self, cleanup);
        return self;
    }
    pub fn showAll(self: *Host) !void {
        try self.show("全部来源", null);
    }
    /// The host string is display context only. Filtering captures stable identity.
    pub fn show(self: *Host, _: []const u8, source: ?catalog.SourceFilter) !void {
        if (self.panel.style.display == .none) self.cx.dispatcher.cancelScrollGesture();
        if (self.refresh_job != null or self.open_job != null or self.delete_job != null) {
            if (self.panel.style.display == .none) {
                self.source = source;
                self.restore_focus = self.cx.focused_handle;
                if (self.cx.focus_manager.activeScope() != self.panel) self.cx.focus_manager.pushScope(self.panel);
                self.pending_reload = true;
            }
            self.panel.setDisplay(.flex);
            self.cx.setFocus(self.query_input.input_container);
            return;
        }
        self.restore_focus = self.cx.focused_handle;
        if (self.cx.focus_manager.activeScope() != self.panel) self.cx.focus_manager.pushScope(self.panel);
        self.generation +%= 1;
        self.source = source;
        self.catalog_failure = false;
        self.model.type_filter = .all;
        self.model.query.clearRetainingCapacity();
        if (self.query_input.value) |value| value.set("");
        self.selected = null;
        self.message.setDisplay(.none);
        self.message_warning = false;
        self.message.setTextColor(theme.current().fg_2);
        self.retry_button.setDisplay(.none);
        S.repaint(self.card, self.colors);
        self.colors = theme.current();
        self.panel.setDisplay(.flex);
        self.refresh_job = try loading.CatalogJob.start(self.archive, self.generation);
        self.needs_rebuild = true;
        self.pending_focus = true;
        self.resize();
        self.cx.setFocus(self.query_input.input_container);
        self.cx.requestRedraw();
    }
    pub fn close(self: *Host) void {
        self.cancelDelete();
        self.close_hint.set(false);
        self.generation +%= 1;
        if (self.open_job) |job| job.cancel.store(true, .release);
        if (self.refresh_job) |job| job.cancel.store(true, .release);
        self.panel.setDisplay(.none);
        if (self.cx.focus_manager.activeScope() == self.panel) self.cx.focus_manager.popScope();
        self.cx.setFocus(if (self.restore_focus) |handle| self.cx.node_registry.resolve(handle, null) else self.cx.root);
        self.cx.requestRedraw();
    }
    fn queryChanged(self: *Host, query: []const u8) void {
        self.cancelDelete();
        self.model.applyFilter(query, self.model.type_filter) catch |err| {
            self.report(err);
            return;
        };
        self.selected = null;
        self.needs_rebuild = true;
        self.cx.requestRedraw();
    }
    fn submit(self: *Host, _: []const u8) void {
        // Search submission only moves focus to the explicit View control.
        if (self.rows.items.len > 0) self.cx.setFocus(self.rows.items[0]);
    }
    fn all(self: *Host) void {
        self.filter(.all);
    }
    fn ssh(self: *Host) void {
        self.filter(.ssh);
    }
    fn local(self: *Host) void {
        self.filter(.local);
    }
    fn filter(self: *Host, kind: catalog.TypeFilter) void {
        self.cancelDelete();
        self.model.applyFilter(self.model.query.items, kind) catch |err| {
            self.report(err);
            return;
        };
        self.selected = null;
        self.needs_rebuild = true;
        self.cx.requestRedraw();
    }
    fn resize(self: *Host) void {
        self.viewport_width = self.cx.viewport.width;
        self.viewport_height = self.cx.viewport.height;
        const width = @min(480, @max(260, self.viewport_width - 24));
        self.card.style.width = .{ .px = width };
        var card_top: f32 = 50;
        if (self.trigger) |trigger| {
            const rect = trigger.globalRect();
            const right = std.math.clamp(self.viewport_width - rect.x - rect.w, 12, @max(12, self.viewport_width - width - 12));
            const top = @max(12, rect.y + rect.h + 12);
            card_top = top;
            self.card.setStyleInline(self.allocator, .{ .inset = .{ .right = .{ .px = right }, .top = .{ .px = top } } });
        }
        const count = self.model.pageEnd() - self.model.pageStart();
        const content_h: f32 = if (self.refresh_job != null or count == 0) 200 else @as(f32, @floatFromInt(count)) * S.row_height + @as(f32, if (self.model.len() > catalog.page_size) 30 else 0);
        const message_height: f32 = if (self.message.style.display == .none) 0 else 56;
        const retry_height: f32 = if (self.retry_button.style.display == .none) 0 else 32;
        const available = self.viewport_height - card_top - 12 - 144 - message_height - retry_height;
        const height = @min(content_h, @max(84, @min(412, available)));
        self.scroll.container.style.height = .{ .px = height };
        self.scroll.state.viewport_height = height;
        self.scroll.state.external_content_height = true;
        self.scroll.state.content_height = content_h;
        for (self.list.children.items) |child| {
            if (child.meta.ownership.meta.test_id) |id| if (std.mem.eql(u8, id, "history.empty")) {
                child.setStyleInline(self.allocator, .{ .height = .{ .px = height } });
            };
        }
        self.card.markLayoutDirty();
        self.scroll.container.markLayoutDirty();
    }
    fn rebuild(self: *Host) !void {
        self.needs_rebuild = false;
        if (self.row_scope) |scope| scope.dispose();
        self.row_scope = null;
        while (self.list.children.items.len > 0) {
            const old = self.list.children.items[self.list.children.items.len - 1];
            self.cx.detachChild(self.list, old);
            self.cx.destroyDetached(old);
        }
        self.rows.clearRetainingCapacity();
        self.delete_buttons.clearRetainingCapacity();
        self.row_indices.clearRetainingCapacity();
        ui.widgets.setScrollY(self.scroll.state, self.scroll.content, 0);
        const rows = try self.scope.childScope();
        self.row_scope = rows;
        for (self.filter_buttons, 0..) |button, i| button.setBackground(if (i == @backingInt(self.model.type_filter)) theme.popupSelection() else ui.Color.TRANSPARENT);
        var count_buffer: [64]u8 = undefined;
        try self.count.setTextContent(self.allocator, if (self.refresh_job != null) "正在读取…" else if (self.catalog_failure) "" else try std.fmt.bufPrint(&count_buffer, "{d} 条记录", .{self.model.len()}));
        self.clear_disabled.set(self.refresh_job != null or self.delete_job != null or self.model.len() == 0);
        self.resize();
        if (self.refresh_job != null or self.model.len() == 0) {
            const label = if (self.refresh_job != null) "正在读取会话历史…" else if (self.catalog_failure) "无法读取会话历史" else if (self.model.query.items.len > 0 or self.model.type_filter != .all) "没有匹配的历史会话" else "还没有会话历史";
            const empty = try ui.box(self.cx, S.emptyBody(self.scroll.state.viewport_height), .{});
            empty.meta.ownership.meta.test_id = "history.empty";
            try empty.appendChild(self.allocator, try ui.iconTint(self.cx, ui.icons.history, theme.current().fg_2, .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .margin = .{ .bottom = 6 }, .flex_shrink = 0 }));
            try empty.appendChild(self.allocator, try ui.text(self.cx, label, S.emptyTitle()));
            if (self.refresh_job == null and !self.catalog_failure) {
                const hint = try ui.text(self.cx, if (self.model.query.items.len > 0 or self.model.type_filter != .all) "试试其他关键词或会话类型。" else "会话结束后，可在这里查看日志。", S.text(12, 400, true));
                hint.meta.ownership.meta.test_id = "history.empty.detail";
                try empty.appendChild(self.allocator, hint);
            }
            try self.list.appendChild(self.allocator, empty);
            return;
        }
        for (self.model.pageStart()..self.model.pageEnd()) |index| {
            const descriptor = self.model.descriptorAt(index).?;
            const entry = descriptor.entry;
            const click = try rows.createState(RowClick, .{ .host = self, .index = index });
            const row = try ui.box(self.cx, S.row(), .{});
            row.meta.ownership.meta.test_id = "history.record";
            try row.appendChild(self.allocator, try ui.iconTint(self.cx, ui.icons.history, theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .margin = .{ .top = 1 }, .flex_shrink = 0 }));
            const main = try ui.box(self.cx, .{ .width = .fill(), .direction = .column, .flex = 1, .min_width = 0, .gap = 4 }, .{});
            try row.appendChild(self.allocator, main);
            const metadata = try ui.box(self.cx, S.metadata(), .{});
            const name = try ui.text(self.cx, if (descriptor.title.len > 0) descriptor.title else entry.host, S.text(13, 500, false));
            name.meta.ownership.meta.test_id = "history.record.title";
            name.setStyleInline(self.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
            const title_hint = try @import("control_hint.zig").mount(self.cx, rows, name, if (descriptor.title.len > 0) descriptor.title else entry.host, .{ .id = "history.record.title.tooltip", .width = 360, .wrap = .char, .layout = .{ .width = .fill(), .flex = 1, .min_width = 0 } });
            try metadata.appendChild(self.allocator, title_hint.wrapper);
            var date_buffer: [64]u8 = undefined;
            try metadata.appendChild(self.allocator, try ui.text(self.cx, S.dateLabel(&date_buffer, entry.ended_ms), S.text(11, 400, true)));
            try main.appendChild(self.allocator, metadata);
            const tail = try ui.box(self.cx, S.metadata(), .{});
            tail.setStyleInline(self.allocator, .{ .height = .{ .px = 28 }, .gap = 8 });
            var duration_buffer: [64]u8 = undefined;
            const detail = try std.fmt.allocPrint(self.allocator, "{s}{s}{s} · {s}", .{ entry.user, if (descriptor.endpoint.len > 0) "@" else "", descriptor.endpoint, S.durationLabel(&duration_buffer, entry.duration_ms) });
            defer self.allocator.free(detail);
            const detail_node = try ui.text(self.cx, detail, S.text(12, 400, true));
            detail_node.meta.ownership.meta.test_id = "history.record.detail";
            detail_node.setStyleInline(self.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
            const detail_hint = try @import("control_hint.zig").mount(self.cx, rows, detail_node, detail, .{ .id = "history.record.detail.tooltip", .width = 360, .wrap = .char, .layout = .{ .width = .fill(), .flex = 1, .min_width = 0 } });
            try tail.appendChild(self.allocator, detail_hint.wrapper);

            try main.appendChild(self.allocator, tail);
            const actions = try ui.box(self.cx, S.rowActions(), .{});
            const tone = stateTone(descriptor);
            const state = try ui.box(self.cx, S.statusTag(tone), .{});
            state.meta.ownership.meta.test_id = "history.record.state";
            try state.appendChild(self.allocator, try ui.text(self.cx, stateLabel(descriptor), S.statusText(tone)));
            try tail.appendChild(self.allocator, state);
            const open = try ui.widgets.Button(.{ .icon_only = true, .a11y_label = "查看历史会话", .icon_asset = ui.icons.eye, .icon_size = @as(f32, 14), .variant = .ghost, .size = .sm, .disabled = if (!descriptor.can_open) ui.Source(bool).of(true) else ui.Source(bool){ .signal = self.actions_disabled }, .base_style = S.rowAction(), .on_click = self.cx.on(RowClick, click, RowClick.open) }).mount(rows, self.cx);
            open.meta.ownership.meta.test_id = "history.record.view";
            const open_hint = try @import("control_hint.zig").mount(self.cx, rows, open, if (descriptor.can_open) "查看历史会话（只读）" else unavailableReason(descriptor), .{ .id = "history.record.view.tooltip" });
            try actions.appendChild(self.allocator, open_hint.wrapper);
            const export_button = try ui.widgets.Button(.{ .icon_only = true, .a11y_label = if (descriptor.replayability == .baseline_unavailable) "导出保留片段" else "导出会话录制", .icon_asset = ui.icons.download, .icon_size = @as(f32, 14), .variant = .ghost, .size = .sm, .disabled = if (!descriptor.can_export) ui.Source(bool).of(true) else ui.Source(bool){ .signal = self.actions_disabled }, .base_style = S.rowAction(), .on_click = self.cx.on(RowClick, click, RowClick.exportRetained) }).mount(rows, self.cx);
            export_button.meta.ownership.meta.test_id = "history.record.export";
            const export_hint = try @import("control_hint.zig").mount(self.cx, rows, export_button, if (descriptor.can_export) (if (descriptor.replayability == .baseline_unavailable) "导出保留片段（asciinema cast）" else "导出会话录制") else "没有可导出的录制内容", .{ .id = "history.record.export.tooltip" });
            try actions.appendChild(self.allocator, export_hint.wrapper);
            const delete = try ui.widgets.Button(.{ .icon_only = true, .a11y_label = "删除会话记录", .icon_asset = ui.icons.trash_2, .icon_size = @as(f32, 14), .variant = .ghost, .size = .sm, .disabled = self.actions_disabled, .base_style = S.rowAction(), .on_click = self.cx.on(RowClick, click, RowClick.remove) }).mount(rows, self.cx);
            delete.meta.ownership.meta.test_id = "history.record.delete";
            try self.delete_buttons.append(self.allocator, delete);
            const delete_hint = try @import("control_hint.zig").mount(self.cx, rows, delete, "删除会话记录", .{ .id = "history.record.delete.tooltip" });
            try actions.appendChild(self.allocator, delete_hint.wrapper);
            try tail.appendChild(self.allocator, actions);
            try self.list.appendChild(self.allocator, row);
            try self.rows.append(self.allocator, open);
            try self.row_indices.append(self.allocator, index);
        }
        if (self.model.len() > catalog.page_size) {
            const paging = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .justify = .end, .gap = 8, .flex_shrink = 0 }, .{});
            const previous = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.chevron_left, .icon_size = 16, .a11y_label = "上一批历史记录", .base_style = S.rowAction(), .variant = .ghost, .size = .sm, .disabled = self.model.page == 0, .on_click = self.cx.on(Host, self, previousPage) }).mount(rows, self.cx);
            const next = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.chevron_right, .icon_size = 16, .a11y_label = "下一批历史记录", .base_style = S.rowAction(), .variant = .ghost, .size = .sm, .disabled = self.model.pageEnd() == self.model.len(), .on_click = self.cx.on(Host, self, nextPage) }).mount(rows, self.cx);
            previous.meta.ownership.meta.test_id = "history.previous";
            next.meta.ownership.meta.test_id = "history.next";
            const previous_hint = try @import("control_hint.zig").mount(self.cx, rows, previous, "上一批历史记录", .{ .id = "history.previous.tooltip" });
            try paging.appendChild(self.allocator, previous_hint.wrapper);
            const next_hint = try @import("control_hint.zig").mount(self.cx, rows, next, "下一批历史记录", .{ .id = "history.next.tooltip" });
            try paging.appendChild(self.allocator, next_hint.wrapper);
            try self.list.appendChild(self.allocator, paging);
        }
    }
    fn previousPage(self: *Host) void {
        self.model.page -|= 1;
        self.selected = null;
        self.needs_rebuild = true;
        self.cx.requestRedraw();
    }
    fn nextPage(self: *Host) void {
        if (self.model.pageEnd() < self.model.len()) self.model.page += 1;
        self.selected = null;
        self.needs_rebuild = true;
        self.cx.requestRedraw();
    }
    fn runRowAction(self: *Host, index: usize, action: Action) !void {
        if (self.delete_job != null) return;
        const descriptor = self.model.descriptorAt(index) orelse return error.InvalidHistoryIndex;
        if (action == .replay) if (self.open_job) |job| {
            if (!std.mem.eql(u8, job.key, descriptor.archive_key)) return error.HistoryLoadBusy;
            return;
        };
        self.selected = index;
        if (!descriptor.can_open and action == .replay) {
            try self.message.setTextContent(self.allocator, unavailableReason(descriptor));
            self.message.setDisplay(.flex);
            self.resize();
            self.cx.requestRedraw();
            return;
        }
        const workspace = self.workspace orelse return error.WorkspaceUnavailable;
        switch (action) {
            .replay => {
                if (workspace.focusArchive(descriptor.archive_key)) {
                    self.close();
                    _ = workspace.focusArchive(descriptor.archive_key);
                    return;
                }
                if (self.open_job != null) return;
                self.open_job = try loading.Job.start(self.archive, descriptor.archive_key, descriptor.manifest_revision, self.generation);
                try self.message.setTextContent(self.allocator, "正在加载记录… 按 Esc 可取消");
                self.message.setDisplay(.flex);
                self.resize();
                self.cx.requestRedraw();
            },
            .export_cast => {
                if (!descriptor.can_export) return error.RecordingUnavailable;
                const Export = @import("session_export.zig");
                const format: Export.Format = if (descriptor.replayability == .baseline_unavailable) .cast else try Export.Format.parse(workspace.app_config.log.export_format);
                const Jobs = @import("session_export_jobs.zig");
                const manager = Jobs.Manager.forCx(self.cx) orelse return error.WorkspaceUnavailable;
                const source: Jobs.Source = .{ .archive_record = try Jobs.ArchiveRecord.capture(std.heap.c_allocator, self.archive, descriptor.archive_key, descriptor.manifest_revision) };
                try manager.selectDestination(source, format, format.defaultFilename());
            },
        }
    }
    fn confirmationAnchor(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *Host = @ptrCast(@alignCast(raw));
        const r = self.confirmation_anchor;
        return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    }
    fn confirmationChanged(self: *Host, open: bool) void {
        if (!open) self.cancelDelete();
    }
    fn confirmationTheme(node: *ui.Node, tokens: *const ui.ThemeTokens, allocator: std.mem.Allocator) void {
        node.setStyleInline(allocator, S.confirmationChrome(tokens));
    }
    fn clearRecords(self: *Host) void {
        self.requestDelete(null) catch |err| self.report(err);
    }
    fn requestDelete(self: *Host, index: ?usize) !void {
        if (self.delete_job != null or self.refresh_job != null or self.open_job != null or self.model.len() == 0) return;
        const job = try loading.DeleteJob.prepare(self.archive);
        errdefer job.deinit();
        if (index) |value| {
            try job.add(self.model.descriptorAt(value) orelse return error.InvalidHistoryIndex);
        } else for (0..self.model.len()) |value| try job.add(self.model.descriptorAt(value).?);
        var buffer: [256]u8 = undefined;
        try self.confirmation_text.setTextContent(self.allocator, try std.fmt.bufPrint(&buffer, "删除这 {d} 条记录？", .{job.targets.items.len}));
        self.delete_job = job;
        self.actions_disabled.set(true);
        self.message.setDisplay(.none);
        self.confirmation_anchor = self.clear_button.globalRect();
        if (index) |value| for (self.row_indices.items, 0..) |row_index, i| {
            if (row_index == value) {
                self.confirmation_anchor = self.delete_buttons.items[i].globalRect();
                break;
            }
        };
        self.confirmation_open.set(true);
        self.clear_disabled.set(true);
        self.cx.setFocus(self.cancel_button);
        self.resize();
        self.cx.requestRedraw();
    }
    fn cancelDelete(self: *Host) void {
        const job = self.delete_job orelse return;
        if (job.thread != null) return;
        self.delete_job = null;
        job.deinit();
        self.actions_disabled.set(false);
        self.confirmation_open.set(false);
        self.clear_disabled.set(self.model.len() == 0);
        self.cx.setFocus(self.query_input.input_container);
        self.resize();
        self.cx.requestRedraw();
    }
    fn confirmDelete(self: *Host) void {
        const job = self.delete_job orelse return;
        if (job.thread != null) return;
        job.start() catch |err| {
            self.report(err);
            return;
        };
        self.confirmation_open.set(false);
        self.message.setTextContent(self.allocator, "正在删除已确认的会话记录…") catch {};
        self.message.setTextColor(theme.current().fg_2);
        self.message.setDisplay(.flex);
        self.needs_rebuild = true;
        self.resize();
        self.cx.requestRedraw();
    }
    fn retry(self: *Host) void {
        if (self.refresh_job != null or self.open_job != null or self.delete_job != null) return;
        self.generation +%= 1;
        self.refresh_job = loading.CatalogJob.start(self.archive, self.generation) catch |err| {
            self.report(err);
            return;
        };
        self.message.setDisplay(.none);
        self.retry_button.setDisplay(.none);
        self.catalog_failure = false;
        self.needs_rebuild = true;
        self.cx.requestRedraw();
    }
    fn report(self: *Host, err: anyerror) void {
        self.message.setTextContent(self.allocator, loading.errorText(err)) catch {};
        self.message_warning = true;
        self.message.setTextColor(historyWarningInk());
        self.message.setDisplay(.flex);
        self.retry_button.setDisplay(.flex);
        self.resize();
        self.cx.requestRedraw();
    }
    pub fn poll(self: *Host) void {
        if (self.delete_job) |job| if (job.done.load(.acquire)) {
            self.delete_job = null;
            self.actions_disabled.set(false);
            defer job.deinit();
            var buffer: [256]u8 = undefined;
            self.message_warning = job.failed > 0;
            if (self.message_warning) {
                self.message.setTextContent(self.allocator, std.fmt.bufPrint(&buffer, "{d} 条记录未能删除：{s}", .{ job.failed, if (job.failure) |err| loading.errorText(err) else "记录正在使用，请稍后重试。" }) catch "部分记录未能删除，请重试。") catch {};
                self.message.setTextColor(historyWarningInk());
                self.message.setDisplay(.flex);
            } else {
                self.message.setDisplay(.none);
            }
            self.selected = null;
            self.pending_reload = true;
            self.cx.setFocus(self.query_input.input_container);
        };
        if (self.refresh_job) |job| if (job.done.load(.acquire)) {
            self.refresh_job = null;
            defer job.deinit();
            if (job.generation == self.generation and self.panel.style.display != .none) {
                if (job.failure) |err| {
                    self.catalog_failure = true;
                    self.report(err);
                } else if (job.catalog) |*loaded| {
                    self.catalog_failure = false;
                    self.model.install(loaded, self.source) catch |err| {
                        self.report(err);
                        return;
                    };
                    job.catalog = null;
                    self.model.applyFilter(self.model.query.items, self.model.type_filter) catch |err| self.report(err);
                }
                self.needs_rebuild = true;
            }
        };
        if (self.open_job) |job| if (job.done.load(.acquire)) {
            self.open_job = null;
            defer job.deinit();
            if (job.generation == self.generation and self.panel.style.display != .none) {
                if (job.failure) |err| self.report(err) else if (job.document) |document| {
                    const workspace = self.workspace orelse return;
                    workspace.openArchiveDocument(document) catch |err| {
                        self.report(err);
                        return;
                    };
                    job.document = null;
                    self.close();
                    _ = workspace.focusArchive(document.record.descriptor.archive_key);
                }
            }
        };
        if (self.pending_reload and self.refresh_job == null and self.open_job == null and self.delete_job == null and self.panel.style.display != .none) {
            self.pending_reload = false;
            self.refresh_job = loading.CatalogJob.start(self.archive, self.generation) catch |err| {
                self.report(err);
                return;
            };
            self.needs_rebuild = true;
        }
        if (self.panel.style.display == .none) return;
        if (!std.meta.eql(self.colors, theme.current())) {
            S.repaint(self.card, self.colors);
            self.colors = theme.current();
            if (self.message_warning) self.message.setTextColor(historyWarningInk());
        }
        const glass = theme.overlayGlass();
        if (self.card.style.glass_params() == null or self.card.style.glass_params().?.backdrop_blur != glass.backdrop_blur) self.card.setStyleInline(self.allocator, .{ .glass = glass });
        if (self.viewport_width != self.cx.viewport.width or self.viewport_height != self.cx.viewport.height) self.resize();
        if (self.needs_rebuild) self.rebuild() catch |err| self.report(err);
        if (self.pending_focus) {
            self.pending_focus = false;
            self.cx.setFocus(self.query_input.input_container);
        }
    }
    fn frame(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.poll();
        return .done;
    }
    fn onPanelEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Host = @ptrCast(@alignCast(raw orelse return .ignored));
        switch (event) {
            .mouse_down => |mouse| {
                const rect = self.card.globalRect();
                if (mouse.x < rect.x or mouse.x > rect.x + rect.w or mouse.y < rect.y or mouse.y > rect.y + rect.h) {
                    self.close();
                    return .stop;
                }
            },
            .key_down => |key| {
                if (key.key == .escape) {
                    if (self.confirmation_open.peek()) {
                        self.cancelDelete();
                        return .stop;
                    }
                    self.close();
                    return .stop;
                }
                if ((key.key == .down or key.key == .up) and !self.confirmation_open.peek() and self.delete_job == null) {
                    if (self.rows.items.len == 0) return .stop;
                    var position: usize = if (key.key == .up) self.rows.items.len - 1 else 0;
                    if (self.selected) |selected| for (self.row_indices.items, 0..) |index, i| if (index == selected) {
                        position = if (key.key == .up) (i + self.rows.items.len - 1) % self.rows.items.len else (i + 1) % self.rows.items.len;
                        break;
                    };
                    self.selected = self.row_indices.items[position];
                    self.cx.setFocus(self.rows.items[position]);
                    const y = @as(f32, @floatFromInt(position)) * S.row_height;
                    const top = self.scroll.state.scroll_y;
                    if (y < top or y + S.row_height > top + self.scroll.state.viewport_height) ui.widgets.setScrollY(self.scroll.state, self.scroll.content, if (y < top) y else y + S.row_height - self.scroll.state.viewport_height);
                    return .stop;
                }
            },
            else => {},
        }
        return .ignored;
    }
    fn cleanup(self: *Host) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.open_job) |job| job.deinit();
        if (self.refresh_job) |job| job.deinit();
        if (self.delete_job) |job| job.deinit();
        self.model.deinit();
        self.rows.deinit(self.allocator);
        self.delete_buttons.deinit(self.allocator);
        self.row_indices.deinit(self.allocator);
        if (self.archive_dir_owned) self.archive.dir.close(self.archive.io);
        self.allocator.destroy(self);
    }
};

fn historyWarningInk() ui.Color {
    const colors = theme.current();
    const alpha: u8 = @intFromFloat(@round(theme.materialParameters().transparency * 255 / 100));
    const veil = theme.baseColors().app.withAlpha(alpha);
    // The new global history list is triggered directly by the workspace (L1).
    const surface = theme.layerBackground(1);
    return theme.patchInk(colors.warn_ink, &.{ theme.patchPaint(surface, theme.patchPaint(veil, ui.Color.BLACK)), theme.patchPaint(surface, theme.patchPaint(veil, ui.Color.WHITE)) });
}
const RowClick = struct {
    host: *Host,
    index: usize,
    fn open(self: *RowClick) void {
        self.host.runRowAction(self.index, .replay) catch |err| self.host.report(err);
    }
    fn remove(self: *RowClick) void {
        self.host.requestDelete(self.index) catch |err| self.host.report(err);
    }
    fn exportRetained(self: *RowClick) void {
        self.host.runRowAction(self.index, .export_cast) catch |err| self.host.report(err);
    }
};
fn stateTone(descriptor: archive_mod.Descriptor) u8 {
    if (notRecorded(descriptor)) return 0;
    if (!descriptor.can_open) return if (descriptor.replayability == .unsupported or descriptor.replayability == .baseline_unavailable) 2 else 3;
    if (descriptor.coverage == .partial or descriptor.coverage == .gapped) return 2;
    if (descriptor.coverage == .retained) return if (descriptor.replayability == .legacy_unverified) 0 else 2;
    return if (descriptor.entry.exit_code == null) 2 else if (descriptor.entry.exit_code.? == 0) 0 else 3;
}

fn stateLabel(descriptor: archive_mod.Descriptor) []const u8 {
    if (notRecorded(descriptor)) return "未录制";
    if (!descriptor.can_open) return if (descriptor.replayability == .unsupported) "版本不支持" else if (descriptor.replayability == .baseline_unavailable) "起始状态缺失" else "录制不可用";
    if (descriptor.coverage == .partial) return "部分记录";
    if (descriptor.coverage == .gapped) return "记录有缺口";
    if (descriptor.coverage == .retained) return if (descriptor.replayability == .legacy_unverified) "旧版记录" else "保留片段";
    return if (descriptor.entry.exit_code == null) "连接中断" else if (descriptor.entry.exit_code.? == 0) "正常结束" else "异常结束";
}

fn unavailableReason(descriptor: archive_mod.Descriptor) []const u8 {
    if (notRecorded(descriptor)) return "该会话未启用录制，没有可回看的内容";
    return switch (descriptor.replayability) {
        .unsupported => "录制版本不受支持，无法回看",
        .baseline_unavailable => "记录起始状态已淘汰，无法准确回放；可导出保留内容",
        else => descriptor.failure orelse "该会话的录制内容不可用",
    };
}

fn notRecorded(descriptor: archive_mod.Descriptor) bool {
    const reason = descriptor.failure orelse return false;
    return std.mem.eql(u8, reason, "RecordingDisabled") or std.mem.eql(u8, reason, "NotRecorded");
}

fn actionStyle() ui.BoxStyle {
    return .{ .height = .{ .px = 28 }, .padding = .{ .left = 8, .right = 8 }, .gap = 5, .font_size = 12, .font_weight = 400, .border = .{ .radius = 6 }, .flex_shrink = 0 };
}
