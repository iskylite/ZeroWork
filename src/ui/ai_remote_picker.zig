//! Inline resource selection. All IO stays with the original FileBindingHost.
const std = @import("std");
const ui = @import("ui");
const files = @import("../host/file_binding_host.zig");
const capture = @import("../host/ai_remote_file_snapshot.zig");
const attachments = @import("../ai/local_text_attachments.zig");
const scope_mod = @import("../ai/tool_scope.zig");
const S = @import("ai_remote_picker_styles.zig");
/// Own the filename content while retaining native Button focus and events.
pub fn filenameButton(scope: *ui.Scope, cx: *ui.Cx, name: []const u8, on_click: ?ui.Handler(void)) !struct { button: *ui.Node, label: *ui.Node } {
    const button_node = try ui.widgets.Button(.{ .a11y_label = name, .variant = .ghost, .base_style = S.option(), .hover_style = S.hover(), .on_click = on_click }).mount(scope, cx);
    const label = try ui.textStyled(cx, S.text, name);
    label.setStyleInline(cx.allocator, S.filenameLabel());
    label.meta.ownership.meta.test_id = "ai.remote.filename";
    try button_node.appendChild(cx.allocator, label);
    return .{ .button = button_node, .label = label };
}
pub const Source = struct { session: @import("../host/identity.zig").SessionHandle, name: []const u8, cwd: []const u8, available: bool };
pub const Callbacks = struct {
    context: *anyopaque,
    ensure: *const fn (*anyopaque, Source) anyerror!files.Bindings,
    live: *const fn (*anyopaque, scope_mod.Owner) ?scope_mod.Scope,
    stage: *const fn (*anyopaque, scope_mod.Owner, *attachments.ContentRef) anyerror!void,
    attach: ?*const fn (*anyopaque, scope_mod.Owner, *attachments.ContentRef) anyerror!void = null,
};
const Active = struct { reader: *capture.Reader, context: capture.Context, delivered: bool = false, direct: bool = false };
const Row = struct {
    view: *View,
    index: usize,
    revision: u64,
    fn check(self: *Row, _: bool) void {
        self.choose();
    }
    fn preview(self: *Row) void {
        if (self.view.revision != self.revision) return;
        const value = self.view.listing.value() orelse return;
        if (self.index >= self.view.filtered_count) return;
        const entry = value.body.listing.entries[self.view.filtered[self.index]];
        if (entry.attributes.kind == .directory) {
            self.choose();
            return;
        }
        if (self.view.selected) |path| self.view.cx.allocator.free(path);
        self.view.selected = self.view.cx.allocator.dupe(u8, entry.absolute_path) catch return;
        self.view.readSelected();
    }
    fn choose(self: *Row) void {
        if (self.view.revision == self.revision) self.view.select(self.index) catch |err| self.view.fail(err);
    }
};
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    host: *files.FileBindingHost,
    callbacks: Callbacks,
    root: *ui.Node = undefined,
    surface: *ui.Node = undefined,
    modal_open: *ui.Signal(bool) = undefined,
    source_label: *ui.Node = undefined,
    source_options: *ui.Signal([]const ui.widgets.SelectOption) = undefined,
    source_value: *ui.Signal(?[]const u8) = undefined,
    source_items: [16]ui.widgets.SelectOption = undefined,
    source_ids: [16][4]u8 = undefined,
    status: *ui.Node = undefined,
    path: *ui.Signal([]const u8),
    filter: *ui.Signal([]const u8),
    input_state: *ui.widgets.input.TextInputState = undefined,
    count: *ui.Signal(usize),
    version: *ui.Signal(u64),
    sources: [16]Source = undefined,
    names: [16][256]u8 = undefined,
    cwds: [16][4097]u8 = undefined,
    source_count: usize = 0,
    source_index: usize = 0,
    owner: ?scope_mod.Owner = null,
    revision: u64 = 0,
    bindings: ?files.Bindings = null,
    listing: capture.ResultRef = .{},
    filtered: [256]usize = undefined,
    filtered_count: usize = 0,
    selected: ?[]u8 = null,
    selections: std.ArrayList([]u8) = .empty,
    queued: std.ArrayList([]u8) = .empty,
    direct_read: bool = false,
    readers: std.ArrayList(Active) = .empty,
    want_list: bool = false,
    want_read: bool = false,
    open_state: bool = false,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, host: *files.FileBindingHost, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .host = host, .callbacks = callbacks, .path = try scope.createText("", .{}), .filter = try scope.createText("", .{}), .count = try scope.createSignal(usize, 0), .version = try scope.createSignal(u64, 0) });
        self.root = try ui.box(cx, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 } }, .{});
        self.modal_open = try scope.createSignal(bool, false);
        const modal = try ui.widgets.Modal(.{ .open = self.modal_open, .width = 760, .max_height = 510, .background = S.theme.current().overlay, .on_open_change = cx.on(View, self, modalChanged) }).mount(scope, cx);
        if (!modal.portaled) if (cx.root) |root| try root.appendChild(cx.allocator, modal.overlay);
        modal.dialog.meta.ownership.meta.test_id = "ai.remote.picker";
        self.surface = modal.body;
        self.surface.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = 8, .padding = ui.Padding.all(20) });
        const heading = try ui.boxStyled(cx, S.row, .{});
        try heading.appendChild(cx.allocator, try ui.textStyled(cx, S.heading, "附加远端文件"));
        try heading.appendChild(cx.allocator, try ui.box(cx, .{ .width = .fill() }, .{}));
        try heading.appendChild(cx.allocator, try self.button("关闭", "ai.remote.close", close));
        try self.surface.appendChild(cx.allocator, heading);
        const source = try ui.boxStyled(cx, S.row, .{});
        self.source_label = try ui.textStyled(cx, S.text, "选择可读来源");
        self.source_label.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
        try source.appendChild(cx.allocator, self.source_label);
        self.source_options = try scope.createList(ui.widgets.SelectOption, &.{});
        self.source_value = try scope.createSignal(?[]const u8, null);
        const source_picker = try ui.widgets.Select(.{ .options = self.source_options, .value = self.source_value, .width = 360, .size = .sm, .on_change = cx.on(View, self, sourceChanged) }).mount(scope, cx);
        source_picker.trigger.meta.ownership.meta.test_id = "ai.remote.source";
        try source.appendChild(cx.allocator, source_picker.wrapper);
        try self.surface.appendChild(cx.allocator, source);
        const path_row = try ui.boxStyled(cx, S.row, .{});
        var input = try ui.widgets.Input(.{ .value = self.path, .placeholder = "绝对远程路径", .on_change = cx.on(View, self, pathChanged) }).mountResult(scope, cx);
        input.input_container.setStyleInline(cx.allocator, S.input());
        @import("ai_composer_controls_styles.zig").tuneInput(&input);
        input.node.meta.ownership.meta.test_id = "ai.remote.path";
        self.input_state = input.state;
        try path_row.appendChild(cx.allocator, input.node);
        try path_row.appendChild(cx.allocator, try self.button("上级", "ai.remote.parent", parent));
        try path_row.appendChild(cx.allocator, try self.button("→", "ai.remote.go", go));
        try self.surface.appendChild(cx.allocator, path_row);
        var filter = try ui.widgets.Input(.{ .value = self.filter, .placeholder = "过滤当前目录", .on_change = cx.on(View, self, filterChanged) }).mountResult(scope, cx);
        filter.input_container.setStyleInline(cx.allocator, S.input());
        @import("ai_composer_controls_styles.zig").tuneInput(&filter);
        filter.node.meta.ownership.meta.test_id = "ai.remote.filter";
        try self.surface.appendChild(cx.allocator, filter.node);
        const list = try ui.widgets.VirtualList(.{ .item_count = self.count, .data_version = self.version, .item_height = 43, .height = 172, .overscan = 1 }).rows(self, renderRow).viewMount(scope, cx);
        list.root.?.setStyleInline(cx.allocator, S.list());
        list.root.?.meta.ownership.meta.test_id = "ai.remote.directory";
        const columns = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 38 }, .direction = .row, .align_items = .center, .padding = .{ .left = 32, .right = 8 }, .gap = 8, .flex_shrink = 0 }, .{});
        const name_heading = try ui.textStyled(cx, S.text, "名称");
        name_heading.setStyleInline(cx.allocator, .{ .width = .fill() });
        try columns.appendChild(cx.allocator, name_heading);
        for ([_][]const u8{ "大小", "修改时间（UTC）" }, 0..) |name, column| {
            const label = try ui.textStyled(cx, S.text, name);
            label.setStyleInline(cx.allocator, .{ .width = .{ .px = if (column == 0) 80 else 134 } });
            try columns.appendChild(cx.allocator, label);
        }
        try self.surface.appendChild(cx.allocator, columns);
        try self.surface.appendChild(cx.allocator, list.root.?);
        const footer = try ui.boxStyled(cx, S.row, .{});
        self.status = try ui.textStyled(cx, S.text, "默认 4 KiB · 最多 64 KiB");
        self.status.meta.ownership.meta.test_id = "ai.remote.status";
        self.status.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
        try footer.appendChild(cx.allocator, self.status);
        try footer.appendChild(cx.allocator, try self.button("读取预览", "ai.remote.read", readSelected));
        try footer.appendChild(cx.allocator, try self.button("附加所选文件", "ai.remote.attach", attachSelected));
        try self.surface.appendChild(cx.allocator, footer);
        try self.surface.appendChild(cx.allocator, try ui.textStyled(cx, S.text, "默认 4 KiB · 最多 64 KiB · 选择文件后读取预览"));
        return self;
    }
    fn modalChanged(self: *View, value: bool) void {
        if (!value and self.open_state) self.close();
    }
    fn button(self: *View, label: []const u8, id: []const u8, comptime handler: *const fn (*View) void) !*ui.Node {
        const button_node = try ui.widgets.Button(.{ .label = label, .variant = .ghost, .base_style = S.button(), .hover_style = S.hover(), .on_click = self.cx.on(View, self, handler) }).mount(self.scope, self.cx);
        button_node.meta.ownership.meta.test_id = id;
        return button_node;
    }
    pub fn open(self: *View, owner: scope_mod.Owner, sources: []const Source) !void {
        self.close();
        self.owner = owner;
        self.source_count = @min(sources.len, self.sources.len);
        for (sources[0..self.source_count], 0..) |source, index| {
            const name_len = @min(source.name.len, self.names[index].len);
            @memcpy(self.names[index][0..name_len], source.name[0..name_len]);
            if (source.cwd.len > self.cwds[index].len) return error.RemotePathTooLong;
            @memcpy(self.cwds[index][0..source.cwd.len], source.cwd);
            self.sources[index] = .{ .session = source.session, .name = self.names[index][0..name_len], .cwd = self.cwds[index][0..source.cwd.len], .available = source.available };
        }
        for (0..self.source_count) |index| {
            const id = try std.fmt.bufPrint(&self.source_ids[index], "{d}", .{index});
            self.source_items[index] = .{ .value = id, .label = self.sources[index].name, .disabled = !self.sources[index].available };
        }
        self.source_options.set(self.source_items[0..self.source_count]);
        self.source_value.set(if (self.source_count > 0) self.source_items[0].value else null);
        self.open_state = true;
        self.modal_open.set(true);
        if (self.source_count == 0) return self.message("当前范围没有可读远程来源");
        self.source_index = 0;
        try self.changeSource();
    }
    pub fn close(self: *View) void {
        self.open_state = false;
        self.owner = null;
        self.want_list = false;
        self.want_read = false;
        self.invalidate();
        self.modal_open.set(false);
    }
    fn invalidate(self: *View) void {
        self.revision +|= 1;
        for (self.readers.items) |active| active.reader.cancel();
        self.listing.release();
        self.count.set(0);
        self.filtered_count = 0;
        self.version.set(self.version.peek() +| 1);
        if (self.selected) |selected| self.cx.allocator.free(selected);
        self.selected = null;
        for (self.selections.items) |path| self.cx.allocator.free(path);
        self.selections.clearRetainingCapacity();
        for (self.queued.items) |path| self.cx.allocator.free(path);
        self.queued.clearRetainingCapacity();
        self.direct_read = false;
    }
    fn sourceChanged(self: *View, value: ?[]const u8) void {
        const id = value orelse return;
        const index = std.fmt.parseInt(usize, id, 10) catch return;
        if (!self.open_state or index >= self.source_count or !self.sources[index].available) return;
        self.source_index = index;
        self.changeSource() catch |err| self.fail(err);
    }
    fn changeSource(self: *View) !void {
        self.invalidate();
        self.bindings = null;
        const source = self.sources[self.source_index];
        self.path.set(source.cwd);
        _ = self.input_state.setText(source.cwd);
        self.filter.set("");
        const identity_label = try std.fmt.allocPrint(self.cx.allocator, "{s} #{d}", .{ source.name, @backingInt(source.session.session_id) });
        defer self.cx.allocator.free(identity_label);
        try self.source_label.setTextContent(self.cx.allocator, identity_label);
        if (!source.available) return self.message("来源已离线，无法读取");
        self.bindings = try self.callbacks.ensure(self.callbacks.context, source);
        self.want_list = source.cwd.len != 0;
        try self.message(if (source.cwd.len == 0) "目录未知，请输入绝对远程路径" else "连接远程文件服务…");
    }
    fn pathChanged(self: *View, _: []const u8) void {
        self.invalidate();
        self.want_list = false;
        self.want_read = false;
    }
    fn filterChanged(self: *View, _: []const u8) void {
        self.applyFilter() catch |err| self.fail(err);
    }
    fn go(self: *View) void {
        capture.validatePath(self.path.peek()) catch |err| {
            self.fail(err);
            return;
        };
        self.invalidate();
        self.want_list = true;
        self.want_read = false;
        self.cx.requestRedraw();
    }
    fn parent(self: *View) void {
        const path = self.path.peek();
        capture.validatePath(path) catch |err| {
            self.fail(err);
            return;
        };
        const trimmed = std.mem.trimEnd(u8, path, "/");
        const value = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |index| path[0..@max(index, 1)] else "/";
        _ = self.input_state.setText(value);
        self.path.set(value);
        self.go();
    }
    fn attachSelected(self: *View) void {
        if (self.callbacks.attach == null or self.selections.items.len == 0 or self.readers.items.len != 0) return;
        for (self.queued.items) |path| self.cx.allocator.free(path);
        self.queued.clearRetainingCapacity();
        for (self.selections.items) |path| {
            const copy = self.cx.allocator.dupe(u8, path) catch return;
            self.queued.append(self.cx.allocator, copy) catch {
                self.cx.allocator.free(copy);
                return;
            };
        }
        self.direct_read = true;
        self.want_read = true;
        self.want_list = false;
        self.cx.requestRedraw();
    }
    fn readSelected(self: *View) void {
        if (self.selected == null) {
            self.message("请先选择文件") catch {};
            return;
        }
        self.direct_read = false;
        self.want_read = true;
        self.want_list = false;
        self.cx.requestRedraw();
    }
    fn liveContext(self: *View, context: capture.Context) ?capture.Context {
        if (!self.open_state or self.owner == null or self.revision != context.source.revision) return null;
        const live = self.callbacks.live(self.callbacks.context, self.owner.?) orelse return null;
        return .{ .scope = live, .source = context.source };
    }
    pub fn safeTick(self: *View) !void {
        var index: usize = 0;
        while (index < self.readers.items.len) {
            const active = &self.readers.items[index];
            _ = active.reader.poll(self.liveContext(active.context));
            if (!active.delivered and active.reader.terminal) {
                active.delivered = true;
                var result = active.reader.take() orelse return error.MissingRemoteResult;
                defer result.release();
                if (self.liveContext(active.context) != null) try self.accept(result, active.direct);
            }
            if (active.reader.cleanupReceipt() == .released and active.reader.retired) {
                try active.reader.deinit();
                _ = self.readers.orderedRemove(index);
                continue;
            }
            index += 1;
        }
        if (self.open_state and self.direct_read and self.readers.items.len == 0 and self.queued.items.len > 0) self.want_read = true;
        if (self.open_state and (self.want_list or self.want_read) and self.readers.items.len == 0) {
            const bindings = self.bindings orelse return;
            const state = self.host.state(bindings.directory) orelse {
                self.want_list = false;
                self.want_read = false;
                return self.message("文件来源连接已关闭，请重新选择来源");
            };
            if (state.phase == .failed or state.phase == .cleanup_unknown) {
                self.want_list = false;
                self.want_read = false;
                return self.message("远程文件连接失败，请重新选择来源");
            }
            if (state.phase == .ready) {
                const live = self.callbacks.live(self.callbacks.context, self.owner.?) orelse {
                    self.close();
                    return;
                };
                const context: capture.Context = .{ .scope = live, .source = .{ .session = self.sources[self.source_index].session, .revision = self.revision, .bindings = bindings } };
                try self.readers.ensureUnusedCapacity(self.cx.allocator, 1);
                const reader = capture.Reader.start(self.cx.allocator, self.host, context, if (self.want_read) (if (self.direct_read) self.queued.items[0] else self.selected.?) else self.path.peek(), if (self.want_read) .{ .read = .{} } else .{ .list = .{} }) catch |err| {
                    self.want_list = false;
                    self.want_read = false;
                    return self.message(@errorName(err));
                };
                self.readers.appendAssumeCapacity(.{ .reader = reader, .context = context, .direct = self.direct_read });
                if (self.direct_read and self.want_read) self.cx.allocator.free(self.queued.orderedRemove(0));
                try self.message(if (self.want_read) (if (self.direct_read) "附加文件…" else "读取预览…") else "读取目录…");
                self.want_list = false;
                self.want_read = false;
            }
        }
        if (self.readers.items.len != 0 or self.want_list or self.want_read) self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }
    fn accept(self: *View, result: capture.ResultRef, direct: bool) !void {
        const value = result.value().?;
        switch (value.body) {
            .failure => |failure| {
                for (self.queued.items) |path| self.cx.allocator.free(path);
                self.queued.clearRetainingCapacity();
                self.direct_read = false;
                try self.message(switch (failure) {
                    .remote => |remote| @tagName(remote),
                    else => @tagName(failure),
                });
            },
            .listing => |listing| {
                self.listing.release();
                self.listing = result.retain();
                try self.applyFilter();
                const details = try std.fmt.allocPrint(self.cx.allocator, "{s} · {d} 项", .{ if (listing.entries.len == 0) "目录为空" else if (listing.truncated) "目录已截断 · 最多 256 项" else "选择文件后读取预览", listing.entries.len });
                defer self.cx.allocator.free(details);
                try self.message(details);
            },
            .text => {
                var reference = try attachments.ContentRef.createRemote(self.cx.allocator, result, self.sources[self.source_index].name);
                defer reference.release();
                if (direct) {
                    const attach = self.callbacks.attach orelse return error.AttachmentUnavailable;
                    try attach(self.callbacks.context, self.owner.?, &reference);
                    try self.message(if (self.queued.items.len == 0) "所选文件已附加" else "继续附加所选文件…");
                } else {
                    try self.callbacks.stage(self.callbacks.context, self.owner.?, &reference);
                    self.close();
                }
            },
        }
    }
    fn applyFilter(self: *View) !void {
        self.filtered_count = 0;
        if (self.listing.value()) |value| if (value.body == .listing) for (value.body.listing.entries, 0..) |entry, index| {
            if (self.filter.peek().len != 0 and std.mem.indexOf(u8, entry.display_name, self.filter.peek()) == null) continue;
            self.filtered[self.filtered_count] = index;
            self.filtered_count += 1;
        };
        self.count.set(self.filtered_count);
        self.version.set(self.version.peek() +| 1);
        if (self.listing.value() != null and self.filtered_count == 0 and self.filter.peek().len != 0) try self.message("没有匹配项 · 清除过滤以查看目录");
    }
    fn renderRow(self: *View, index: usize, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        const value = self.listing.value() orelse return error.StaleRemoteRow;
        if (index >= self.filtered_count) return error.StaleRemoteRow;
        const entry = value.body.listing.entries[self.filtered[index]];
        const row = try scope.createState(Row, .{ .view = self, .index = index, .revision = self.revision });
        var selected = false;
        for (self.selections.items) |path| if (std.mem.eql(u8, path, entry.absolute_path)) {
            selected = true;
            break;
        };
        const container = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 43 }, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .left = 8, .right = 8 }, .background = if (selected) S.theme.current().selection else ui.Color.TRANSPARENT, .flex_shrink = 0 }, .{});
        const checked = try scope.createSignal(bool, selected);
        const checkbox = try ui.widgets.Checkbox(.{ .checked = ui.split(checked, cx.on(Row, row, Row.check)), .disabled = entry.attributes.kind != .file, .box_size = @as(f32, 14), .label = "" }).mount(scope, cx);
        checkbox.meta.ownership.meta.test_id = "ai.remote.entry";
        try container.appendChild(cx.allocator, checkbox);
        const icon = if (entry.attributes.kind == .directory) try ui.iconTint(cx, ui.icons.folder, S.theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }) else try ui.iconTint(cx, @import("file_workspace_icons.zig").asset(entry.display_name), @import("file_workspace_icons.zig").color(entry.display_name), .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } });
        try container.appendChild(cx.allocator, icon);
        const filename = try filenameButton(scope, cx, entry.display_name, cx.on(Row, row, Row.preview));
        const button_node = filename.button;
        button_node.meta.ownership.meta.test_id = "ai.remote.preview";
        const name_cell = try ui.box(cx, .{ .width = .fill(), .min_width = 0, .direction = .row, .align_items = .center }, .{});
        try name_cell.appendChild(cx.allocator, button_node);
        try container.appendChild(cx.allocator, name_cell);
        var size_buffer: [40]u8 = undefined;
        const size_text = if (entry.attributes.size) |size| try std.fmt.bufPrint(&size_buffer, "{d} B", .{size}) else "—";
        var time_buffer: [40]u8 = undefined;
        const modified_text = if (entry.attributes.modified_at) |seconds| value: {
            if (seconds > 253402300799) break :value "—";
            const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
            const yd = epoch.getEpochDay().calculateYearDay();
            const md = yd.calculateMonthDay();
            const day = epoch.getDaySeconds();
            break :value try std.fmt.bufPrint(&time_buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ yd.year, @backingInt(md.month), md.day_index + 1, day.getHoursIntoDay(), day.getMinutesIntoHour() });
        } else "—";
        for ([_][]const u8{ size_text, modified_text }, 0..) |value_text, column| {
            const info = try ui.textStyled(cx, S.text, value_text);
            info.setStyleInline(cx.allocator, .{ .width = .{ .px = if (column == 0) 80 else 134 }, .min_width = 0, .flex_shrink = 0 });
            try container.appendChild(cx.allocator, info);
        }
        return container;
    }
    fn select(self: *View, index: usize) !void {
        const value = self.listing.value() orelse return error.StaleRemoteRow;
        const entry = value.body.listing.entries[self.filtered[index]];
        const path = try self.cx.allocator.dupe(u8, entry.absolute_path);
        defer self.cx.allocator.free(path);
        if (entry.attributes.kind == .directory) {
            _ = self.input_state.setText(path);
            self.path.set(path);
            self.go();
            return;
        }
        if (entry.attributes.kind != .file) return self.message("此项不是可读取的普通文件");
        self.revision +|= 1;
        for (self.readers.items) |active| active.reader.cancel();
        for (self.queued.items) |queued_path| self.cx.allocator.free(queued_path);
        self.queued.clearRetainingCapacity();
        self.direct_read = false;
        self.want_read = false;
        if (self.selected) |previous| self.cx.allocator.free(previous);
        self.selected = try self.cx.allocator.dupe(u8, path);
        for (self.selections.items, 0..) |chosen, selected_index| if (std.mem.eql(u8, chosen, path)) {
            self.cx.allocator.free(self.selections.orderedRemove(selected_index));
            self.version.set(self.version.peek() +| 1);
            try self.message("已取消选择");
            return;
        };
        const copy = try self.cx.allocator.dupe(u8, path);
        errdefer self.cx.allocator.free(copy);
        try self.selections.append(self.cx.allocator, copy);
        self.version.set(self.version.peek() +| 1);
        const selection_status = try std.fmt.allocPrint(self.cx.allocator, "已选择 {d} 个文件", .{self.selections.items.len});
        defer self.cx.allocator.free(selection_status);
        try self.message(selection_status);
    }
    fn message(self: *View, value: []const u8) !void {
        try self.status.setTextContent(self.cx.allocator, value);
        self.cx.requestRedraw();
    }
    fn fail(self: *View, err: anyerror) void {
        self.message(@errorName(err)) catch {};
    }
    pub fn release(self: *View) error{Busy}!void {
        if (self.readers.items.len != 0) return error.Busy;
        self.readers.deinit(self.cx.allocator);
        self.selections.deinit(self.cx.allocator);
        self.queued.deinit(self.cx.allocator);
    }
    /// A tab close must retire captures before releasing its original file
    /// service. Other sources cannot stand in for an awaiting operation.
    pub fn stopSource(self: *View, owner: @import("../host/identity.zig").SessionHandle) files.readonly.ReleaseReceipt {
        var affected = self.open_state and self.source_count != 0 and self.sources[self.source_index].session.eql(owner);
        for (self.readers.items) |active| if (active.context.source.session.eql(owner)) {
            affected = true;
        };
        if (!affected) return .released;
        self.close();
        self.safeTick() catch {};
        var receipt: files.readonly.ReleaseReceipt = .released;
        for (self.readers.items) |active| if (active.context.source.session.eql(owner)) {
            if (active.reader.cleanupReceipt() == .unknown) return .unknown;
            receipt = .awaiting;
        };
        return receipt;
    }
    pub fn shutdown(self: *View) bool {
        self.close();
        self.safeTick() catch {};
        return self.readers.items.len == 0;
    }
};
