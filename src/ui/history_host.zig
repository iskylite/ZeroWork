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
    trigger: ?*ui.Node = null,
    filter_buttons: [3]*ui.Node,
    footer: *ui.Node,
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
        try head.appendChild(cx.allocator, close_button);
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
        const retry_button = try ui.widgets.Button(.{ .label = "重新读取", .variant = .ghost, .size = .sm, .on_click = cx.on(Host, self, retry) }).mount(scope, cx);
        retry_button.meta.ownership.meta.test_id = "history.retry";
        retry_button.setDisplay(.none);
        try card.appendChild(cx.allocator, retry_button);
        const footer = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 18 }, .direction = .row, .align_items = .center, .gap = 8, .margin = .{ .top = 12 }, .flex_shrink = 0 }, .{});
        footer.meta.ownership.meta.test_id = "history.footer";
        try footer.appendChild(cx.allocator, try ui.text(cx, "已关闭会话 · 按结束时间排序", S.text(12, 400, true)));
        try footer.appendChild(cx.allocator, try ui.spacer(cx));
        try footer.appendChild(cx.allocator, try ui.text(cx, "Esc 关闭", S.text(11, 400, true)));
        try card.appendChild(cx.allocator, footer);
        self.* = .{ .allocator = cx.allocator, .cx = cx, .scope = scope, .panel = panel, .card = card, .list = list, .count = count, .message = message, .query_input = query_input, .scroll = scroll, .close_button = close_button, .filter_buttons = filter_buttons, .footer = footer, .retry_button = retry_button, .archive = .{ .allocator = cx.allocator, .io = cx.io, .dir = dir }, .model = undefined, .colors = theme.current() };
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
        if (self.refresh_job != null or self.open_job != null) {
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
        self.generation +%= 1;
        if (self.open_job) |job| job.cancel.store(true, .release);
        if (self.refresh_job) |job| job.cancel.store(true, .release);
        self.panel.setDisplay(.none);
        if (self.cx.focus_manager.activeScope() == self.panel) self.cx.focus_manager.popScope();
        self.cx.setFocus(if (self.restore_focus) |handle| self.cx.node_registry.resolve(handle, null) else self.cx.root);
        self.cx.requestRedraw();
    }
    fn queryChanged(self: *Host, query: []const u8) void {
        self.model.applyFilter(query, self.model.type_filter) catch |err| {
            self.report(err);
            return;
        };
        self.selected = null;
        self.needs_rebuild = true;
        self.cx.requestRedraw();
    }
    fn submit(self: *Host, _: []const u8) void {
        if (self.model.len() > 0) self.runRowAction(self.selected orelse self.model.pageStart(), .replay) catch |err| self.report(err);
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
        const width = @min(440, @max(260, self.viewport_width - 24));
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
        const content_h: f32 = if (self.refresh_job != null or count == 0) 110 else @as(f32, @floatFromInt(count)) * S.row_height + @as(f32, if (self.model.len() > catalog.page_size) 30 else 0);
        const message_height: f32 = if (self.message.style.display == .none) 0 else 56;
        const retry_height: f32 = if (self.retry_button.style.display == .none) 0 else 32;
        const available = self.viewport_height - card_top - 12 - 184 - message_height - retry_height;
        const height = @min(content_h, @max(84, @min(412, available)));
        self.scroll.container.style.height = .{ .px = height };
        self.scroll.state.viewport_height = height;
        self.scroll.state.external_content_height = true;
        self.scroll.state.content_height = content_h;
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
        self.row_indices.clearRetainingCapacity();
        ui.widgets.setScrollY(self.scroll.state, self.scroll.content, 0);
        const rows = try self.scope.childScope();
        self.row_scope = rows;
        for (self.filter_buttons, 0..) |button, i| button.setBackground(if (i == @backingInt(self.model.type_filter)) theme.popupSelection() else ui.Color.TRANSPARENT);
        var count_buffer: [64]u8 = undefined;
        try self.count.setTextContent(self.allocator, if (self.refresh_job != null) "正在读取…" else if (self.catalog_failure) "" else try std.fmt.bufPrint(&count_buffer, "{d} 条记录", .{self.model.len()}));
        self.resize();
        if (self.refresh_job != null or self.model.len() == 0) {
            const label = if (self.refresh_job != null) "正在读取会话历史…" else if (self.catalog_failure) "无法读取会话历史" else if (self.model.query.items.len > 0) "没有匹配的历史会话" else "还没有会话历史";
            const empty = try ui.text(self.cx, label, S.emptyTitle());
            empty.meta.ownership.meta.test_id = "history.empty";
            empty.setStyleInline(self.allocator, .{ .width = .fill(), .height = .{ .px = 100 }, .justify = .center, .align_items = .center });
            try self.list.appendChild(self.allocator, empty);
            return;
        }
        for (self.model.pageStart()..self.model.pageEnd()) |index| {
            const descriptor = self.model.descriptorAt(index).?;
            const entry = descriptor.entry;
            const click = try rows.createState(RowClick, .{ .host = self, .index = index });
            const row = try ui.widgets.Button(.{ .label = "", .icon_only = true, .icon_asset = ui.icons.history, .icon_size = @as(f32, 16), .icon_tint = theme.current().fg_2, .a11y_label = if (descriptor.title.len > 0) descriptor.title else entry.host, .variant = .ghost, .base_style = S.row(), .on_click = self.cx.on(RowClick, click, RowClick.open) }).mount(rows, self.cx);
            row.meta.ownership.meta.test_id = "history.record";
            row.setStyleInline(self.allocator, S.row());
            if (row.children.items.len > 0) row.children.items[0].style.margin.top = 3;
            const main = try ui.box(self.cx, .{ .width = .fill(), .direction = .column, .flex = 1, .min_width = 0, .gap = 4 }, .{});
            try row.appendChild(self.allocator, main);
            const metadata = try ui.box(self.cx, S.metadata(), .{});
            const name = try ui.text(self.cx, if (descriptor.title.len > 0) descriptor.title else entry.host, S.text(13, 500, false));
            name.meta.ownership.meta.test_id = "history.record.title";
            name.setStyleInline(self.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
            try metadata.appendChild(self.allocator, name);
            var date_buffer: [64]u8 = undefined;
            try metadata.appendChild(self.allocator, try ui.text(self.cx, S.dateLabel(&date_buffer, entry.ended_ms), S.text(11, 400, true)));
            try main.appendChild(self.allocator, metadata);
            const tail = try ui.box(self.cx, S.metadata(), .{});
            var duration_buffer: [64]u8 = undefined;
            const detail = try std.fmt.allocPrint(self.allocator, "{s}{s}{s} · {s}", .{ entry.user, if (descriptor.endpoint.len > 0) "@" else "", descriptor.endpoint, S.durationLabel(&duration_buffer, entry.duration_ms) });
            defer self.allocator.free(detail);
            const detail_node = try ui.text(self.cx, detail, S.text(12, 400, true));
            detail_node.setStyleInline(self.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
            try tail.appendChild(self.allocator, detail_node);
            try tail.appendChild(self.allocator, try ui.text(self.cx, stateLabel(descriptor), S.text(11, 400, true)));
            try main.appendChild(self.allocator, tail);
            if (!descriptor.can_open and descriptor.replayability == .baseline_unavailable and descriptor.entry.cast_path.len > 0) {
                const export_button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.download, .icon_size = @as(f32, 16), .a11y_label = "导出保留录制", .size = .sm, .on_click = self.cx.on(RowClick, click, RowClick.exportRetained) }).mount(rows, self.cx);
                export_button.meta.ownership.meta.test_id = "history.record.export";
                try row.appendChild(self.allocator, export_button);
            }
            try self.list.appendChild(self.allocator, row);
            try self.rows.append(self.allocator, row);
            try self.row_indices.append(self.allocator, index);
        }
        if (self.model.len() > catalog.page_size) {
            const paging = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .justify = .end, .gap = 8, .flex_shrink = 0 }, .{});
            const previous = try ui.widgets.Button(.{ .label = "上一批", .variant = .ghost, .size = .sm, .disabled = self.model.page == 0, .on_click = self.cx.on(Host, self, previousPage) }).mount(rows, self.cx);
            const next = try ui.widgets.Button(.{ .label = "下一批", .variant = .ghost, .size = .sm, .disabled = self.model.pageEnd() == self.model.len(), .on_click = self.cx.on(Host, self, nextPage) }).mount(rows, self.cx);
            previous.meta.ownership.meta.test_id = "history.previous";
            next.meta.ownership.meta.test_id = "history.next";
            try paging.appendChild(self.allocator, previous);
            try paging.appendChild(self.allocator, next);
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
                const Export = @import("session_export.zig");
                const format: Export.Format = if (descriptor.replayability == .baseline_unavailable) .cast else try Export.Format.parse(workspace.app_config.log.export_format);
                const sdk = self.cx.system_sdk orelse return error.NativeDialogUnavailable;
                const captured = try @import("session_export_jobs.zig").ArchiveRecord.capture(std.heap.c_allocator, self.archive, descriptor.archive_key, descriptor.manifest_revision);
                var owned = captured;
                var path_buffer: [4096]u8 = undefined;
                const target = sdk.runDialog(.{ .kind = .save_file, .title = format.defaultFilename() }, &path_buffer) catch |err| {
                    owned.deinit();
                    return err;
                };
                const destination = target orelse {
                    owned.deinit();
                    return;
                };
                const manager = @import("session_export_jobs.zig").Manager.forCx(self.cx) orelse {
                    owned.deinit();
                    return error.WorkspaceUnavailable;
                };
                try manager.start(.{ .archive_record = captured }, format, destination);
            },
        }
    }
    fn retry(self: *Host) void {
        if (self.refresh_job != null or self.open_job != null) return;
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
        if (self.pending_reload and self.refresh_job == null and self.open_job == null and self.panel.style.display != .none) {
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
                    self.close();
                    return .stop;
                }
                if (key.key == .down or key.key == .up) {
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
        self.model.deinit();
        self.rows.deinit(self.allocator);
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
    fn exportRetained(self: *RowClick) void {
        self.host.runRowAction(self.index, .export_cast) catch |err| self.host.report(err);
    }
};
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
