//! Immutable dual-pane file projection. No IO, PTY, sample data or authority
//! derives from focus. Callback slices are borrowed only until it returns.
const std = @import("std");
const ui = @import("ui");
const identity = @import("../host/identity.zig");
const S = @import("file_workspace_styles.zig");
const drag = ui.interaction.drag;
pub const Side = enum { local, remote };
pub const Endpoint = struct { kind: enum { local_fs, sftp }, binding_id: u64, binding_generation: u64 };
pub const Stamp = struct { owner: identity.SessionHandle, endpoint: Endpoint, request_id: u64, directory_revision: u64 };
pub const State = enum { loading, ready, empty, failed, stale };
pub const Kind = enum { file, directory, symlink, unknown };
pub const Sort = struct { column: enum { name, size, modified } = .name, descending: bool = false };
pub const Entry = struct {
    /// Stable selection key is this exact original absolute path, not a row.
    absolute_path: []const u8,
    raw_name: []const u8,
    display_name: []const u8,
    kind: Kind,
    size: ?u64 = null,
    modified_label: []const u8 = "",
    modified_full: []const u8 = "",
};
pub const PaneProjection = struct {
    stamp: Stamp,
    selection_revision: u64 = 1,
    title: []const u8,
    subtitle: []const u8,
    badge: []const u8,
    resolved_path: []const u8,
    entries: []const Entry = &.{},
    selected_keys: []const []const u8 = &.{},
    anchor: ?[]const u8 = null,
    focused_key: ?[]const u8 = null,
    sort: Sort = .{},
    state: State = .ready,
    failure: []const u8 = "",
    writable: bool = false,
    can_transfer: bool = false,
    can_mkdir: bool = false,
    can_back: bool = false,
    can_parent: bool = true,
    navigation_enabled: bool = true,
};
pub const Projection = struct { revision: u64, owner: identity.SessionHandle, panes: [2]PaneProjection };
pub const Selection = struct { keys: []const []const u8, anchor: ?[]const u8, focused_key: ?[]const u8 };
pub const Transfer = struct { selection: Selection, destination: Stamp, directory: []const u8, target_entry: ?[]const u8 = null };
pub const Navigation = struct { requested_path: []const u8, base_directory: []const u8 };
pub const Action = union(enum) {
    navigate: Navigation,
    back,
    parent,
    refresh,
    history,
    sort: Sort,
    selection: Selection,
    context: Selection,
    copy_paths: Selection,
    transfer: Transfer,
    new_folder,
    recover,
};
pub const Envelope = struct { side: Side, stamp: Stamp, projection_revision: u64, selection_revision: u64, action: Action };
pub const Callbacks = struct { context: *anyopaque, action: *const fn (*anyopaque, Envelope) anyerror!void };
const Owned = struct {
    arena: std.heap.ArenaAllocator,
    value: Projection,
    fn init(allocator: std.mem.Allocator, source: Projection, previous: ?Projection) !Owned {
        try validate(source);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var result = source;
        for (&result.panes, source.panes, 0..) |*pane, input, index| {
            var value = input;
            // A read failure is never a successful empty directory. Retain
            // the last successful rows/path rather than manufacturing emptiness.
            if (previous) |old| if (value.state == .failed or value.state == .stale) {
                const before = old.panes[index];
                if (std.meta.eql(value.stamp.endpoint, before.stamp.endpoint)) {
                    value.entries = before.entries;
                    value.resolved_path = before.resolved_path;
                    value.selected_keys = before.selected_keys;
                    value.anchor = before.anchor;
                    value.focused_key = before.focused_key;
                    value.stamp.directory_revision = before.stamp.directory_revision;
                }
            };
            pane.* = value;
            pane.title = try a.dupe(u8, value.title);
            pane.subtitle = try a.dupe(u8, value.subtitle);
            pane.badge = try a.dupe(u8, value.badge);
            pane.resolved_path = try a.dupe(u8, value.resolved_path);
            pane.failure = try a.dupe(u8, value.failure);
            const entries = try a.alloc(Entry, value.entries.len);
            for (value.entries, entries) |entry, *copy| {
                copy.* = entry;
                copy.absolute_path = try a.dupe(u8, entry.absolute_path);
                copy.raw_name = try a.dupe(u8, entry.raw_name);
                copy.display_name = try a.dupe(u8, entry.display_name);
                copy.modified_label = try a.dupe(u8, entry.modified_label);
                copy.modified_full = try a.dupe(u8, entry.modified_full);
            }
            pane.entries = entries;
            var keys: std.ArrayList([]const u8) = .empty;
            for (value.selected_keys) |key| {
                if (entryIndex(entries, key)) |i| {
                    if (!parentEntry(entries[i]) and !contains(keys.items, key)) try keys.append(a, try a.dupe(u8, key));
                }
            }
            pane.selected_keys = try keys.toOwnedSlice(a);
            pane.anchor = if (value.anchor) |key| if (entryIndex(entries, key) != null) try a.dupe(u8, key) else null else null;
            pane.focused_key = if (value.focused_key) |key| if (entryIndex(entries, key) != null) try a.dupe(u8, key) else null else null;
        }
        return .{ .arena = arena, .value = result };
    }
};
const DragSource = struct { arena: std.heap.ArenaAllocator, side: Side, stamp: Stamp, selection_revision: u64, selection: Selection, directory: []const u8 };
const DropTarget = struct { side: Side, stamp: Stamp, directory: []const u8, entry: ?[]const u8 };
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    root: *ui.Node,
    callbacks: Callbacks,
    panes: [2]*Pane,
    source: ?Owned = null,
    pending: ?Owned = null,
    paint_colors: S.theme.Colors,
    drag_source: ?DragSource = null,
    drop_side: ?Side = null,
    drop_path: [4096]u8 = undefined,
    drop_path_len: usize = 0,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .root = undefined, .callbacks = callbacks, .panes = undefined, .paint_colors = S.theme.current() });
        self.root = try ui.boxStyled(cx, S.root, .{});
        self.root.meta.ownership.meta.test_id = "files.workspace";
        self.root.setDisplay(.none);
        for (&self.panes, 0..) |*pane, i| {
            pane.* = try Pane.mount(self, @fromBackingInt(@intCast(i)));
            try self.root.appendChild(cx.allocator, pane.*.root);
        }
        try scope.onCleanup(View, self, cleanup);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    /// Queues a fully owned projection; apply at the next layout safe point.
    /// The host accumulates paged results and publishes only a final snapshot.
    pub fn update(self: *View, source: Projection) !void {
        const previous = if (self.pending) |owned| owned.value else if (self.source) |owned| owned.value else null;
        if (previous) |old| {
            if (!old.owner.eql(source.owner)) return error.FileOwnerChanged;
            if (source.revision <= old.revision) return error.StaleFileProjection;
            for (old.panes, source.panes) |before, after| {
                if (std.meta.eql(before.stamp.endpoint, after.stamp.endpoint) and (after.stamp.request_id < before.stamp.request_id or after.stamp.directory_revision < before.stamp.directory_revision or after.selection_revision < before.selection_revision)) return error.StaleFileProjection;
            }
        }
        const next = try Owned.init(self.cx.allocator, source, previous);
        if (self.pending) |*old| old.arena.deinit();
        self.pending = next;
        self.cx.requestRedraw();
    }
    pub fn flush(self: *View) !bool {
        if (self.pending == null) return false;
        const next = self.pending.?;
        self.pending = null;
        var old = self.source;
        self.source = next;
        defer if (old) |*value| value.arena.deinit();
        for (self.panes, 0..) |pane, i| try pane.apply(if (old) |value| value.value.panes[i] else null);
        self.root.setDisplay(.flex);
        return true;
    }
    /// Same global palette/material publication used by the other app views.
    pub fn retheme(self: *View) void {
        S.repaint(self.root, self.paint_colors);
        self.paint_colors = S.theme.current();
        for (self.panes) |pane| pane.paint.set(pane.paint.peek() +% 1);
        self.cx.requestRedraw();
    }
    fn latest(self: *View) ?Projection {
        return if (self.pending) |owned| owned.value else if (self.source) |owned| owned.value else null;
    }
    fn beginDrag(self: *View, row: *Row) !void {
        self.clearDrag();
        const projection = self.latest() orelse return error.StaleFileProjection;
        const source = projection.panes[@backingInt(row.pane.side)];
        if (!fresh(source) or !source.can_transfer or !std.meta.eql(source.stamp, row.stamp) or source.selected_keys.len == 0 or !contains(source.selected_keys, row.key)) return error.FileTransferUnavailable;
        var arena = std.heap.ArenaAllocator.init(self.cx.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const keys = try a.alloc([]const u8, source.selected_keys.len);
        for (source.selected_keys, keys) |key, *copy| copy.* = try a.dupe(u8, key);
        const selected: Selection = .{ .keys = keys, .anchor = if (source.anchor) |key| try a.dupe(u8, key) else null, .focused_key = if (source.focused_key) |key| try a.dupe(u8, key) else null };
        const directory = try a.dupe(u8, source.resolved_path);
        self.drag_source = .{ .arena = arena, .side = row.pane.side, .stamp = source.stamp, .selection_revision = source.selection_revision, .selection = selected, .directory = directory };
    }
    fn targetAt(self: *View, point: drag.Point) ?DropTarget {
        const source = self.drag_source orelse return null;
        const projection = self.latest() orelse return null;
        const side: Side = if (source.side == .local) .remote else .local;
        const pane = self.panes[@backingInt(side)];
        const target = projection.panes[@backingInt(side)];
        if (!fresh(target) or !target.writable or !within(pane.data_clip.globalRect(), point)) return null;
        if (rowAt(pane.list.content, point)) |node| {
            const key = (if (node.behavior.interaction.a11y) |value| value.label else null) orelse return null;
            const index = entryIndex(target.entries, key) orelse return null;
            const entry = target.entries[index];
            if (entry.kind != .directory) return null;
            return .{ .side = side, .stamp = target.stamp, .directory = entry.absolute_path, .entry = entry.absolute_path };
        }
        return .{ .side = side, .stamp = target.stamp, .directory = target.resolved_path, .entry = null };
    }
    fn hoverDrag(self: *View, point: drag.Point) void {
        const target = self.targetAt(point);
        const side: ?Side = if (target) |value| value.side else null;
        const path: []const u8 = if (target) |value| value.directory else "";
        if (path.len > self.drop_path.len) return;
        if (self.drop_side == side and std.mem.eql(u8, self.drop_path[0..self.drop_path_len], path)) return;
        self.drop_side = side;
        @memcpy(self.drop_path[0..path.len], path);
        self.drop_path_len = path.len;
        for (self.panes) |pane| {
            pane.drag_preview.setDisplay(if (side != null and side.? == pane.side) .flex else .none);
            pane.paint.set(pane.paint.peek() +% 1);
        }
        if (side) |value| {
            const pane = self.panes[@backingInt(value)];
            pane.drag_target.setTextContent(self.cx.allocator, path) catch {};
            if (self.drag_source) |source| {
                var label_buffer: [80]u8 = undefined;
                pane.drag_title.setTextContent(self.cx.allocator, std.fmt.bufPrint(&label_buffer, "松开{s} {d} 项", .{ if (source.side == .local) "上传" else "下载", source.selection.keys.len }) catch "松开打开目标核对") catch {};
                pane.drag_origin.setTextContent(self.cx.allocator, source.directory) catch {};
            }
        }
        self.cx.requestRedraw();
    }
    fn finishDrag(self: *View, point: drag.Point) !void {
        const source = self.drag_source orelse return;
        defer self.clearDrag();
        const target = self.targetAt(point) orelse return;
        const projection = self.latest() orelse return error.StaleFileProjection;
        const current = projection.panes[@backingInt(source.side)];
        if (!std.meta.eql(current.stamp, source.stamp) or current.selection_revision != source.selection_revision) return error.StaleFileSelection;
        try self.callbacks.action(self.callbacks.context, .{ .side = source.side, .stamp = source.stamp, .projection_revision = projection.revision, .selection_revision = source.selection_revision, .action = .{ .transfer = .{ .selection = source.selection, .destination = target.stamp, .directory = target.directory, .target_entry = target.entry } } });
    }
    fn clearDrag(self: *View) void {
        if (self.drag_source) |*source| source.arena.deinit();
        self.drag_source = null;
        self.drop_side = null;
        self.drop_path_len = 0;
        for (self.panes) |pane| {
            pane.drag_preview.setDisplay(.none);
            pane.paint.set(pane.paint.peek() +% 1);
        }
        self.cx.requestRedraw();
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        var dirty = self.flush() catch false;
        if (self.source != null) for (self.panes) |pane| {
            if (pane.filter_pending) {
                pane.filter_pending = false;
                pane.apply(null) catch |err| pane.report(err);
                ui.widgets.setScrollY(pane.list.state, pane.list.content, 0);
                dirty = true;
            }
            dirty = pane.geometry() or dirty;
        };
        if (dirty) self.cx.requestRedraw();
        return if (dirty) .needs_layout else .done;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.source) |*owned| owned.arena.deinit();
        if (self.pending) |*owned| owned.arena.deinit();
        if (self.drag_source) |*owned| owned.arena.deinit();
        for (self.panes) |pane| pane.filtered.deinit(self.cx.allocator);
    }
};

pub const Pane = struct {
    view: *View,
    side: Side,
    root: *ui.Node,
    title: *ui.Node,
    subtitle: *ui.Node,
    endpoint_tip: *ui.Signal([]const u8),
    stale_notice: *ui.Node = undefined,
    badge: *ui.Node,
    drag_preview: *ui.Node = undefined,
    drag_title: *ui.Node = undefined,
    drag_origin: *ui.Node = undefined,
    drag_target: *ui.Node = undefined,
    path: ui.widgets.input.InputResult,
    path_value: *ui.Signal([]const u8),
    context_button: *ui.Node = undefined,
    history_button: *ui.Node = undefined,
    nav_disabled: *ui.Signal(bool),
    back_disabled: *ui.Signal(bool),
    parent_disabled: *ui.Signal(bool),
    write_disabled: *ui.Signal(bool),
    mkdir_disabled: *ui.Signal(bool),
    table: *ui.Node,
    toolbar: *ui.Node = undefined,
    data_clip: *ui.Node = undefined,
    draft_editor: ?*ui.Node = null,
    draft_result: ?*ui.Node = null,
    draft_open: bool = false,
    draft_result_open: bool = false,
    header: *ui.Node,
    headings: [3]*ui.Node,
    heading_buttons: [3]*ui.Node,
    all_checked: *ui.Signal(bool),
    mixed: *ui.Signal(bool),
    list: ui.widgets.ScrollAreaResult,
    virtual: *ui.widgets.VirtualListState,
    empty: *ui.Node,
    empty_text: *ui.Node,
    footer: *ui.Node,
    summary: *ui.Node,
    mode: *ui.Node,
    actions: *ui.Node,
    status: *ui.Node,
    error_box: *ui.Node,
    error_text: *ui.Node,
    error_detail: *ui.Node,
    recovery_detail: *ui.Node,
    paint: *ui.Signal(u64),
    column_width: f32 = S.min_columns,
    name_width: f32 = S.min_columns - S.columns_fixed,
    size_width: f32 = 76,
    date_width: f32 = 140,
    empty_y: f32 = S.header_height,
    focus_requested: bool = false,
    filter: ui.widgets.input.InputResult = undefined,
    filter_value: *ui.Signal([]const u8) = undefined,
    filter_pending: bool = false,
    filtered: std.ArrayList(Entry) = .empty,

    fn mount(view: *View, side: Side) !*Pane {
        const cx = view.cx;
        const scope = view.scope;
        const self = try scope.createState(Pane, .{ .view = view, .side = side, .root = undefined, .title = undefined, .subtitle = undefined, .endpoint_tip = try scope.createText("", .{}), .badge = undefined, .path = undefined, .path_value = try scope.createText("", .{}), .nav_disabled = try scope.createSignal(bool, true), .back_disabled = try scope.createSignal(bool, true), .parent_disabled = try scope.createSignal(bool, true), .write_disabled = try scope.createSignal(bool, true), .mkdir_disabled = try scope.createSignal(bool, true), .table = undefined, .header = undefined, .headings = undefined, .heading_buttons = undefined, .all_checked = try scope.createSignal(bool, false), .mixed = try scope.createSignal(bool, false), .list = undefined, .virtual = undefined, .empty = undefined, .empty_text = undefined, .footer = undefined, .summary = undefined, .mode = undefined, .actions = undefined, .status = undefined, .error_box = undefined, .error_text = undefined, .error_detail = undefined, .recovery_detail = undefined, .paint = try scope.createSignal(u64, 0) });
        self.root = try ui.boxStyled(cx, S.card, .{});
        self.root.meta.ownership.meta.test_id = if (side == .local) "files.local" else "files.remote";
        self.toolbar = try ui.boxStyled(cx, S.toolbar, .{});
        self.toolbar.meta.ownership.meta.test_id = "files.toolbar";
        try self.root.appendChild(cx.allocator, self.toolbar);
        const top = try ui.box(cx, S.line(30), .{});
        try self.toolbar.appendChild(cx.allocator, top);
        try top.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get(if (side == .local) "laptop" else "folder-open").?, S.theme.current().fg_2, S.icon(16)));
        const endpoint = try ui.widgets.Tooltip(.{ .text = self.endpoint_tip, .open_delay_ms = 450 }).mount(scope, cx);
        endpoint.wrapper.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .flex_shrink = 0 });
        endpoint.trigger.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .flex_shrink = 0 });
        self.title = try label(cx, endpoint.trigger, S.title, "");
        self.title.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .flex_shrink = 0 });
        try top.appendChild(cx.allocator, endpoint.wrapper);
        const badge = try ui.boxStyled(cx, S.badge, .{});
        badge.setStyleInline(cx.allocator, .{ .max_width = 150, .min_width = 0, .flex_shrink = 1, .overflow = .hidden });
        self.badge = try label(cx, badge, S.secondary, "");
        self.badge.setStyleInline(cx.allocator, .{ .min_width = 0, .overflow = .hidden });
        if (self.badge.getText()) |value| {
            var text_style = value;
            text_style.text_overflow = .ellipsis;
            self.badge.setText(text_style);
        }
        try top.appendChild(cx.allocator, badge);
        try top.appendChild(cx.allocator, try ui.spacer(cx));
        _ = try self.button(top, "refresh-cw", "刷新当前目录", .refresh, null, 24);
        self.subtitle = try label(cx, self.root, S.subtitle, "");
        self.subtitle.setStyleInline(cx.allocator, .{ .height = .{ .px = 18 }, .flex_shrink = 0, .width = .fill(), .overflow = .hidden });
        const path_row = try ui.box(cx, S.line(30), .{});
        try self.toolbar.appendChild(cx.allocator, path_row);
        _ = try self.button(path_row, "arrow-left", "返回上一个目录", .back, self.back_disabled, 24);
        _ = try self.button(path_row, "arrow-up", "上级目录", .parent, self.parent_disabled, 24);
        const field = try ui.boxStyled(cx, S.pathField, .{});
        try path_row.appendChild(cx.allocator, field);
        self.path = try ui.widgets.Input(.{ .value = self.path_value, .growable = true, .embedded = true, .disabled = self.nav_disabled, .on_submit = cx.on(Pane, self, inputSubmitted) }).mountResult(scope, cx);
        self.path.node.setStyleInline(cx.allocator, S.pathInput());
        self.path.input_container.setStyleInline(cx.allocator, S.pathInput());
        self.path.state.font_size = S.path_font;
        self.path.state.line_height = 17;
        self.path.state.char_width = S.path_font * 0.6;
        if (self.path.state.text_display_node) |display| if (display.getText()) |current| {
            var text_style = current;
            text_style.font_size = S.path_font;
            text_style.line_height = 17 / S.path_font;
            display.setText(text_style);
        };
        self.path.state.dirty = true;
        self.path.input_container.meta.ownership.meta.test_id = "files.path";
        try field.appendChild(cx.allocator, self.path.node);
        self.history_button = try self.button(field, "chevron-down", "目录历史", .history, self.nav_disabled, 14);
        const filter_row = try ui.box(cx, S.line(30), .{});
        filter_row.meta.ownership.meta.test_id = "files.filter_row";
        try self.toolbar.appendChild(cx.allocator, filter_row);
        const filter_field = try ui.boxStyled(cx, S.pathField, .{});
        try filter_row.appendChild(cx.allocator, filter_field);
        try filter_field.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.search, S.theme.current().fg_2, S.icon(14)));
        self.filter_value = try scope.createText("", .{});
        self.filter = try ui.widgets.Input(.{ .value = self.filter_value, .placeholder = "筛选当前目录…", .growable = true, .embedded = true, .on_change = cx.on(Pane, self, filterChanged) }).mountResult(scope, cx);
        self.filter.node.setStyleInline(cx.allocator, S.pathInput());
        self.filter.input_container.setStyleInline(cx.allocator, S.pathInput());
        self.filter.input_container.meta.ownership.meta.test_id = "files.filter";
        try filter_field.appendChild(cx.allocator, self.filter.node);
        _ = try self.button(filter_row, "plus", "新建文件夹", .new_folder, self.mkdir_disabled, 24);
        self.context_button = try self.button(filter_row, "ellipsis", "当前文件操作", .context, null, 24);
        self.stale_notice = try label(cx, self.root, S.secondary, "上次列表 · 已过期");
        self.stale_notice.setDisplay(.none);
        self.table = try ui.boxStyled(cx, S.table, .{});
        try self.root.appendChild(cx.allocator, self.table);
        const header_clip = try ui.boxStyled(cx, S.headerClip, .{});
        try self.table.appendChild(cx.allocator, header_clip);
        self.header = try ui.box(cx, S.columns(S.min_columns), .{});
        self.header.setStyleInline(cx.allocator, .{ .height = .{ .px = S.header_height } });
        self.header.meta.ownership.meta.test_id = "files.columns";
        try header_clip.appendChild(cx.allocator, self.header);
        const select_cell = try ui.box(cx, S.column(24), .{});
        select_cell.setStyleInline(cx.allocator, .{ .height = .{ .px = S.header_height } });
        const select_all = try ui.widgets.Checkbox(.{ .checked = ui.split(self.all_checked, cx.on(Pane, self, selectAll)), .indeterminate = self.mixed, .box_size = @as(f32, 16), .label = "" }).mount(scope, cx);
        select_all.meta.ownership.meta.test_id = "files.select_all";
        select_all.behavior.interaction.a11y.?.label = "选择当前目录全部项目";
        try select_cell.appendChild(cx.allocator, select_all);
        try self.header.appendChild(cx.allocator, select_cell);
        inline for ([_][]const u8{ "名称 ↑", "大小", "修改时间" }, 0..) |text, i| {
            const control = try scope.createState(Control, .{ .pane = self, .kind = .sort, .column = @intCast(i) });
            const width: f32 = if (i == 0) self.name_width else if (i == 1) 76 else 140;
            const button_ = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = text, .base_style = S.sortButton(width), .on_click = cx.on(Control, control, Control.run) }).mount(scope, cx);
            button_.meta.ownership.meta.test_id = switch (i) {
                0 => "files.sort.name",
                1 => "files.sort.size",
                else => "files.sort.modified",
            };
            self.headings[i] = try label(cx, button_, if (i == 1) S.numeric else S.secondary, text);
            self.headings[i].setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
            self.heading_buttons[i] = button_;
            try self.header.appendChild(cx.allocator, button_);
        }
        const list = try ui.widgets.VirtualList(.{ .item_count = @as(usize, 0), .item_height = S.row_height, .scroll_direction = .both, .content_width = S.min_columns, .overscan = 2 }).mountWithContext(scope, cx, self, null, renderItem);
        self.virtual = list.state;
        self.list = .{ .container = list.container, .content = list.state.content_node, .state = list.state.scroll_state };
        self.list.container.setStyleInline(cx.allocator, S.viewport());
        self.list.container.meta.ownership.meta.test_id = "files.rows";
        // ScrollArea padding reserves scrollbar metrics, but its overflow clip
        // still covers the full container. Give data its own real clip inside
        // that padding so row paint and hit targets cannot enter the 12px rail.
        // Keep the component's scrollbars as later siblings above this clip.
        const data_clip = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .min_height = 0, .overflow = .hidden, .overflow_hidden = true }, .{});
        data_clip.meta.ownership.meta.test_id = "files.data_clip";
        self.data_clip = data_clip;
        cx.detachChild(self.list.container, self.list.content);
        try self.list.container.insertChildBefore(cx.allocator, data_clip, if (self.list.container.children.items.len > 0) self.list.container.children.items[0] else null);
        try data_clip.appendChild(cx.allocator, self.list.content);
        try self.table.appendChild(cx.allocator, self.list.container);
        self.empty = try ui.boxStyled(cx, S.empty, .{});
        try self.empty.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.folder_open, S.theme.current().fg_2, S.icon(18)));
        self.empty_text = try label(cx, self.empty, S.title, "");
        try self.table.appendChild(cx.allocator, self.empty);
        self.footer = try ui.boxStyled(cx, S.footer, .{});
        self.footer.meta.ownership.meta.test_id = "files.footer";
        try self.root.appendChild(cx.allocator, self.footer);
        self.summary = try label(cx, self.footer, S.secondary, "");
        self.summary.setStyleInline(cx.allocator, S.flexible());
        self.mode = try label(cx, self.footer, S.secondary, "");
        self.actions = self.footer;
        self.status = try label(cx, self.actions, S.secondary, "");
        self.status.setStyleInline(cx.allocator, .{ .max_width = 180, .min_width = 0, .overflow = .hidden });
        _ = try self.button(self.actions, if (side == .local) "upload" else "download", if (side == .local) "上传所选" else "下载所选", .transfer, self.write_disabled, 28);
        self.error_box = try ui.boxStyled(cx, S.errorBox, .{});
        self.error_box.meta.ownership.meta.test_id = "files.error";
        self.error_text = try label(cx, self.error_box, S.errorText, "");
        self.error_detail = try label(cx, self.error_box, S.secondary, "上次列表 · 已过期");
        self.recovery_detail = try label(cx, self.error_box, S.secondary, "");
        self.recovery_detail.setDisplay(.none);
        const recovery = try ui.box(cx, S.line(30), .{});
        try recovery.appendChild(cx.allocator, try ui.spacer(cx));
        _ = try self.button(recovery, "plug", "恢复原文件连接", .recover, null, 24);
        _ = try self.button(recovery, "refresh-cw", "重新读取当前目录", .refresh, null, 24);
        try self.error_box.appendChild(cx.allocator, recovery);
        self.drag_preview = try ui.boxStyled(cx, S.dragPreview, .{});
        self.drag_preview.meta.ownership.meta.test_id = "files.drag.preview";
        self.drag_title = try label(cx, self.drag_preview, S.title, "");
        self.drag_origin = try label(cx, self.drag_preview, S.secondary, "");
        self.drag_target = try label(cx, self.drag_preview, S.secondary, "");
        self.drag_target.meta.ownership.meta.test_id = "files.drag.target";
        self.drag_preview.setDisplay(.none);
        try self.root.appendChild(cx.allocator, self.drag_preview);
        self.error_box.setDisplay(.none);
        try self.root.appendChild(cx.allocator, self.error_box);
        return self;
    }

    pub fn projection(self: *const Pane) ?PaneProjection {
        return if (self.view.source) |source| source.value.panes[@backingInt(self.side)] else null;
    }
    /// Only row presentation is filtered. Authority, selections and stamps stay
    /// in the original immutable projection; all row indices share this slice.
    fn rowProjection(self: *const Pane) ?PaneProjection {
        var p = self.projection() orelse return null;
        p.entries = self.filtered.items;
        return p;
    }
    fn filterChanged(self: *Pane, _: []const u8) void {
        self.filter_pending = true;
        self.view.cx.requestRedraw();
    }
    fn rebuildFilter(self: *Pane) !void {
        const p = self.projection() orelse return;
        self.filtered.clearRetainingCapacity();
        for (p.entries) |entry| if (matchesFilter(entry, self.filter_value.peek())) {
            try self.filtered.append(self.view.cx.allocator, entry);
        };
    }
    /// The draft is a form, never a filesystem Entry or a selected file. Its
    /// stable Input lives outside recycled VirtualList rows but inside the same
    /// clipped viewport; one empty virtual row reserves its scrolling position.
    pub fn installDraft(self: *Pane, editor: *ui.Node, result: *ui.Node) !void {
        if (self.draft_editor != null) return error.FileDraftAlreadyInstalled;
        try self.data_clip.appendChild(self.view.cx.allocator, editor);
        try self.root.appendChild(self.view.cx.allocator, result);
        self.draft_editor = editor;
        self.draft_result = result;
        editor.setDisplay(.none);
        result.setDisplay(.none);
    }
    pub fn setDraft(self: *Pane, editing: bool, result_visible: bool) void {
        const changed = self.draft_open != editing;
        self.draft_open = editing;
        self.draft_result_open = result_visible;
        if (self.draft_editor) |node| node.setDisplay(if (editing) .flex else .none);
        if (self.draft_result) |node| node.setDisplay(if (result_visible) .flex else .none);
        if (self.rowProjection()) |p| {
            self.actions.setDisplay(if (result_visible or p.state == .failed or p.state == .stale) .none else .flex);
            self.error_box.setDisplay(if (!result_visible and (p.state == .failed or p.state == .stale)) .flex else .none);
            self.empty.setDisplay(if (p.entries.len == 0 and !editing) .flex else .none);
            if (changed) ui.widgets.virtual_list.updateItemCount(self.virtual, p.entries.len + @intFromBool(editing));
            if (editing and changed) ui.widgets.virtual_list.ensureVisible(self.virtual, self.draftIndex(p));
        }
        self.root.markLayoutDirty();
        self.view.cx.requestRedraw();
    }
    pub fn locate(self: *Pane, key: []const u8) void {
        if (self.projection()) |original| {
            if (entryIndex(original.entries, key) == null) return;
            if (!matchesFilter(original.entries[entryIndex(original.entries, key).?], self.filter_value.peek())) {
                self.filter_value.set("");
                self.rebuildFilter() catch return;
                self.filter_pending = true;
                ui.widgets.virtual_list.updateItemCount(self.virtual, self.filtered.items.len + @intFromBool(self.draft_open));
            }
        }
        const p = self.rowProjection() orelse return;
        const at = entryIndex(p.entries, key) orelse return;
        ui.widgets.virtual_list.ensureVisible(self.virtual, self.virtualIndex(p, at));
        self.focus_requested = true;
        self.view.cx.requestRedraw();
    }
    /// Resize can shorten the real clipped body while an inline draft keeps
    /// focus. Use that current viewport, including the scrollbar rail padding.
    pub fn revealDraft(self: *Pane) bool {
        if (!self.draft_open) return false;
        const p = self.rowProjection() orelse return false;
        const height = self.data_clip.globalRect().h;
        if (height <= 0) return false;
        self.list.state.viewport_height = height;
        const before = self.list.state.scroll_y;
        ui.widgets.virtual_list.ensureVisible(self.virtual, self.draftIndex(p));
        return @abs(before - self.list.state.scroll_y) > 0.01;
    }
    fn draftIndex(_: *Pane, p: PaneProjection) usize {
        var at: usize = 0;
        while (at < p.entries.len and p.entries[at].kind == .directory) : (at += 1) {}
        return at;
    }
    fn virtualIndex(self: *Pane, p: PaneProjection, at: usize) usize {
        return at + @intFromBool(self.draft_open and at >= self.draftIndex(p));
    }
    fn button(self: *Pane, parent_: *ui.Node, icon: []const u8, help: []const u8, kind: Control.ControlKind, disabled: ?*ui.Signal(bool), size: f32) !*ui.Node {
        const cx = self.view.cx;
        const scope = self.view.scope;
        const control = try scope.createState(Control, .{ .pane = self, .kind = kind });
        const node = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.get(icon).?, .icon_size = @min(@as(f32, 16), size), .a11y_label = help, .base_style = S.iconButton(size), .disabled = if (disabled) |signal| ui.Source(bool){ .signal = signal } else ui.Source(bool){ .value = false }, .on_click = cx.on(Control, control, Control.run) }).mount(scope, cx);
        node.meta.ownership.meta.test_id = switch (kind) {
            .new_folder => "files.new_folder",
            .refresh => "files.refresh",
            .context => "files.context",
            .back => "files.back",
            .parent => "files.parent",
            .history => "files.history",
            .submit_path => "files.open_path",
            .transfer => "files.transfer",
            .recover => "files.recover",
            .sort => "files.sort",
        };
        const tooltip = try ui.widgets.Tooltip(.{ .text = help, .open_delay_ms = @as(f32, 450) }).mount(scope, cx);
        tooltip.wrapper.setStyleInline(cx.allocator, .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 });
        try tooltip.trigger.appendChild(cx.allocator, node);
        try parent_.appendChild(cx.allocator, tooltip.wrapper);
        return node;
    }
    fn apply(self: *Pane, before: ?PaneProjection) !void {
        const cx = self.view.cx;
        try self.rebuildFilter();
        const p = self.projection().?;
        const rows = self.rowProjection().?;
        if (cx.pressed_node) |pressed| if (isDescendant(self.root, pressed)) {
            const drag_ack = if (self.view.drag_source) |source| source.side == self.side and std.meta.eql(source.stamp, p.stamp) and source.selection_revision == p.selection_revision else false;
            if (!drag_ack and (before == null or !std.meta.eql(before.?.stamp, p.stamp) or before.?.selection_revision != p.selection_revision)) cx.cancelPointerInteractions(.explicit);
        };
        try self.title.setTextContent(cx.allocator, if (self.side == .local) "本地文件" else "远端文件");
        try self.subtitle.setTextContent(cx.allocator, p.subtitle);
        self.subtitle.setDisplay(.none);
        self.endpoint_tip.set(p.subtitle);
        try self.badge.setTextContent(cx.allocator, if (self.side == .local) p.badge else p.title);
        const path_changed = before == null or !std.meta.eql(before.?.stamp.endpoint, p.stamp.endpoint) or !std.mem.eql(u8, before.?.resolved_path, p.resolved_path);
        const editing = if (cx.focused_node) |focused| isDescendant(self.path.node, focused) else false;
        if (path_changed or (!editing and !self.path.state.imeIsComposing())) self.path_value.set(p.resolved_path);
        self.nav_disabled.set(!p.navigation_enabled);
        self.back_disabled.set(!p.navigation_enabled or !p.can_back);
        self.parent_disabled.set(!p.navigation_enabled or !p.can_parent or std.mem.eql(u8, p.resolved_path, "/"));
        self.mkdir_disabled.set(!fresh(p) or !p.writable or !p.can_mkdir);
        const destination = self.view.source.?.value.panes[1 - @backingInt(self.side)];
        self.write_disabled.set(!fresh(p) or !p.can_transfer or p.selected_keys.len == 0 or !fresh(destination) or !destination.writable);
        var selectable: usize = 0;
        var visible_selected: usize = 0;
        for (rows.entries) |entry| if (!parentEntry(entry)) {
            selectable += 1;
            visible_selected += @intFromBool(contains(p.selected_keys, entry.absolute_path));
        };
        self.all_checked.set(selectable > 0 and visible_selected == selectable);
        self.mixed.set(visible_selected > 0 and visible_selected < selectable);
        const has_error = p.state == .failed or p.state == .stale;
        self.stale_notice.setDisplay(if (has_error and p.entries.len > 0) .flex else .none);
        if (has_error and p.entries.len > 0) {
            var retained: [4608]u8 = undefined;
            try self.stale_notice.setTextContent(cx.allocator, std.fmt.bufPrint(&retained, "上次列表 · {s} · 已过期", .{p.resolved_path}) catch "上次列表 · 已过期");
        }
        self.error_detail.setDisplay(.none);
        self.error_box.setDisplay(if (has_error and !self.draft_result_open) .flex else .none);
        self.actions.setDisplay(if (has_error or self.draft_result_open) .none else .flex);
        if (has_error) {
            var message: [512]u8 = undefined;
            const value = std.fmt.bufPrint(&message, "{s}目录读取失败 · {s}", .{ if (self.side == .remote) "远程" else "本地", p.failure }) catch "目录读取失败";
            try self.error_text.setTextContent(cx.allocator, value);
            try self.recovery_detail.setTextContent(cx.allocator, if (self.side == .remote) "恢复文件连接后重新读取当前目录。" else "重新读取当前目录。");
        }
        var summary: [256]u8 = undefined;
        const total_text = if (has_error) "" else if (p.state == .loading) "正在读取目录…" else if (p.selected_keys.len == 0) try std.fmt.bufPrint(&summary, "{d} 项", .{selectable}) else blk: {
            var known: u64 = 0;
            var known_files: usize = 0;
            var unknown: usize = 0;
            var directories: usize = 0;
            for (p.entries) |entry| if (contains(p.selected_keys, entry.absolute_path)) {
                if (entry.kind == .directory) {
                    directories += 1;
                } else if (entry.size) |size| {
                    known +|= size;
                    known_files += 1;
                } else {
                    unknown += 1;
                }
            };
            var size_buffer: [64]u8 = undefined;
            const size = try formatSize(&size_buffer, known);
            if (directories > 0 and unknown > 0) break :blk try std.fmt.bufPrint(&summary, "已选 {d} 项 · {d} 目录 · {d} 大小未知", .{ p.selected_keys.len, directories, unknown });
            if (unknown > 0) break :blk if (known_files > 0) try std.fmt.bufPrint(&summary, "已选 {d} 项 · {s} · {d} 大小未知", .{ p.selected_keys.len, size, unknown }) else try std.fmt.bufPrint(&summary, "已选 {d} 项 · 大小未知", .{p.selected_keys.len});
            if (directories > 0) break :blk if (known_files > 0) try std.fmt.bufPrint(&summary, "已选 {d} 项 · {s} · {d} 目录", .{ p.selected_keys.len, size, directories }) else try std.fmt.bufPrint(&summary, "已选 {d} 项 · {d} 目录", .{ p.selected_keys.len, directories });
            break :blk try std.fmt.bufPrint(&summary, "已选 {d} 项 · {s}", .{ p.selected_keys.len, size });
        };
        try self.summary.setTextContent(cx.allocator, total_text);
        // Focus is expressed by the focused row; keep the selection footer for file facts and actions.
        self.mode.setDisplay(.none);
        try self.status.setTextContent(cx.allocator, if (has_error) "" else if (p.state == .loading) "正在读取目录…" else if (!p.can_transfer) "" else if (p.selected_keys.len == 0) "未选择项目" else "");
        for (self.headings, 0..) |heading, i| {
            const column = @backingInt(p.sort.column);
            var text: [64]u8 = undefined;
            const value = try std.fmt.bufPrint(&text, "{s}{s}", .{ ([_][]const u8{ "名称", "大小", "修改时间" })[i], if (column == i) (if (p.sort.descending) " ↓" else " ↑") else "" });
            try heading.setTextContent(cx.allocator, value);
        }
        self.empty.setDisplay(if (rows.entries.len == 0 and !self.draft_open and !has_error) .flex else .none);
        try self.empty_text.setTextContent(cx.allocator, if (has_error) "目录读取失败" else if (p.state == .loading) "正在读取目录…" else if (self.filter_value.peek().len > 0) "没有匹配的项目" else "目录为空");
        // Keep row nodes for selection-only acknowledgements, otherwise the
        // native double-click target would be replaced after the first click.
        if (before == null or !sameRows(before.?, p)) ui.widgets.virtual_list.updateItemCount(self.virtual, rows.entries.len + @intFromBool(self.draft_open));
        if (path_changed) ui.widgets.setScrollY(self.list.state, self.list.content, 0);
        self.paint.set(self.paint.peek() +% 1);
        self.root.markLayoutDirty();
    }
    fn geometry(self: *Pane) bool {
        const cx = self.view.cx;
        const available = self.data_clip.globalRect().w;
        const width = @max(@as(f32, 320), available);
        const compact = available < S.min_columns;
        self.size_width = if (compact) 60 else 76;
        self.date_width = if (compact) 0 else 140;
        self.toolbar.setStyleInline(cx.allocator, .{ .padding = if (compact) .{ .top = 8, .right = 8, .bottom = 9, .left = 8 } else .{ .top = 14, .right = 13, .bottom = 11, .left = 13 } });
        self.heading_buttons[2].setDisplay(if (compact) .none else .flex);
        var changed = false;
        if (@abs(width - self.column_width) > 0.01) {
            self.column_width = width;
            self.name_width = width - (if (compact) @as(f32, 60) else S.columns_fixed - 216) - self.size_width - self.date_width;
            self.header.setStyleInline(cx.allocator, .{ .width = .{ .px = width } });
            self.heading_buttons[0].setStyleInline(cx.allocator, .{ .width = .{ .px = self.name_width } });
            self.heading_buttons[1].setStyleInline(cx.allocator, .{ .width = .{ .px = self.size_width } });
            self.heading_buttons[2].setStyleInline(cx.allocator, .{ .width = .{ .px = self.date_width } });
            self.list.content.setStyleInline(cx.allocator, .{ .width = .{ .px = width } });
            self.list.state.content_width = width;
            self.virtual.props.content_width = width;
            self.paint.set(self.paint.peek() +% 1);
            changed = true;
        }
        const rail: f32 = if (available < 320) 12 else 0;
        if (self.list.container.style.padding.bottom != rail) {
            self.list.container.setStyleInline(cx.allocator, .{ .padding = .{ .bottom = rail } });
            changed = true;
        }
        _ = ui.widgets.scroll_area.applyHorizontalScroll(self.list.state, 0, 1, .wheel);
        const x = self.list.state.contentTranslateX();
        if (@abs(self.header.style.translate_x - x) > 0.01) {
            self.header.setStyleInline(cx.allocator, .{ .translate_x = x });
            changed = true;
        }
        if (@abs(self.list.content.style.translate_x - x) > 0.01) {
            self.list.content.setStyleInline(cx.allocator, .{ .translate_x = x });
            changed = true;
        }
        if (self.draft_editor) |editor| if (self.draft_open) {
            const top = @as(f32, @floatFromInt(self.draftIndex(self.rowProjection().?))) * S.row_height + self.list.state.contentTranslateY();
            if (@abs(editor.style.translate_x - x) > 0.01 or @abs(editor.style.translate_y - top) > 0.01 or editor.globalRect().w != width) {
                editor.setStyleInline(cx.allocator, .{ .width = .{ .px = width }, .translate_x = x, .translate_y = top });
                changed = true;
            }
        };
        const body = self.list.container.globalRect();
        const empty_y = S.header_height + @max(@as(f32, 0), (body.h - rail - 128) / 2);
        if (self.empty_y != empty_y) {
            self.empty_y = empty_y;
            self.empty.setStyleInline(cx.allocator, .{ .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = empty_y } } });
            changed = true;
        }
        if (self.focus_requested and self.view.pending == null) {
            const p = self.projection().?;
            if (p.focused_key) |key| if (findRow(self.list.content, key)) |node| {
                self.focus_requested = false;
                cx.setFocus(node);
            };
        }
        return changed;
    }
    fn emit(self: *Pane, action: Action) !void {
        if (self.view.pending != null) return error.StaleFileProjection;
        const p = self.projection() orelse return error.FileProjectionUnavailable;
        try self.view.callbacks.action(self.view.callbacks.context, .{ .side = self.side, .stamp = p.stamp, .projection_revision = self.view.source.?.value.revision, .selection_revision = p.selection_revision, .action = action });
    }
    fn report(self: *Pane, err: anyerror) void {
        self.status.setTextContent(self.view.cx.allocator, @errorName(err)) catch {};
        self.view.cx.requestRedraw();
    }
    fn submitPath(self: *Pane) void {
        const p = self.projection() orelse return;
        if (!p.navigation_enabled or self.path.state.imeIsComposing()) return;
        const path_ = self.path_value.peek();
        if (path_.len == 0 or std.mem.indexOfScalar(u8, path_, 0) != null) return self.report(error.InvalidPath);
        self.emit(.{ .navigate = .{ .requested_path = path_, .base_directory = p.resolved_path } }) catch |err| self.report(err);
    }
    fn inputSubmitted(self: *Pane, _: []const u8) void {
        self.submitPath();
    }
    fn selectAll(self: *Pane, checked: bool) void {
        self.selectAllFallible(checked) catch |err| self.report(err);
    }
    fn selectAllFallible(self: *Pane, checked: bool) !void {
        const p = self.projection() orelse return;
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(self.view.cx.allocator);
        for (p.selected_keys) |key| if (entryIndex(self.filtered.items, key) == null) {
            try keys.append(self.view.cx.allocator, key);
        };
        if (checked) for (self.filtered.items) |entry| if (!parentEntry(entry)) {
            try keys.append(self.view.cx.allocator, entry.absolute_path);
        };
        try self.emit(.{ .selection = .{ .keys = keys.items, .anchor = if (keys.items.len > 0) keys.items[0] else null, .focused_key = p.focused_key } });
    }
    fn renderItem(node: *ui.Node, index: usize, cx: *ui.Cx, raw: ?*anyopaque) void {
        const self: *Pane = @ptrCast(@alignCast(raw.?));
        ui.view.renderInto(self.view.scope, cx, node, renderRow, self, .{index}, "file workspace row") catch |err| {
            self.report(err);
            _ = ui.widgets.virtual_list.markPoolNodeRenderIncomplete(node);
        };
    }
    fn renderRow(self: *Pane, index: usize, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        const p = self.rowProjection() orelse return error.FileProjectionUnavailable;
        const draft_at = self.draftIndex(p);
        if (self.draft_open and index == draft_at) return ui.box(cx, S.columns(self.column_width), .{});
        const entry_at = index - @intFromBool(self.draft_open and index > draft_at);
        if (entry_at >= p.entries.len) return error.StaleFileProjection;
        const entry = p.entries[entry_at];
        const key = try scope.createText(entry.absolute_path, .{});
        const checked = try scope.createSignal(bool, contains(p.selected_keys, entry.absolute_path));
        const style = try scope.createSignal(S.ButtonStyle, S.fileRow(self.column_width, checked.peek(), sameOptional(p.focused_key, entry.absolute_path)));
        const row = try scope.createState(Row, .{ .pane = self, .stamp = p.stamp, .key = key.peek(), .node = undefined, .columns = undefined, .name_cell = undefined, .checked = checked, .style = style, .tooltip_open = try scope.createSignal(bool, false) });
        const node = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = key, .base_style = style, .on_click = cx.on(Row, row, Row.clicked), .on_event = @as(*const fn (ui.events.Event, ?*anyopaque) ui.events.EventResult, Row.event), .event_context = @as(?*anyopaque, row) }).mount(scope, cx);
        node.meta.ownership.meta.test_id = "files.row";
        row.node = node;
        row.columns = try ui.box(cx, S.columns(self.column_width), .{});
        try node.appendChild(cx.allocator, row.columns);
        const check_cell = try ui.box(cx, S.column(24), .{});
        const checkbox = try ui.widgets.Checkbox(.{ .checked = ui.split(checked, cx.on(Row, row, Row.check)), .disabled = parentEntry(entry), .box_size = @as(f32, 16), .label = "" }).mount(scope, cx);
        checkbox.meta.ownership.meta.test_id = "files.row.select";
        checkbox.behavior.interaction.a11y.?.label = row.key;
        try check_cell.appendChild(cx.allocator, checkbox);
        try row.columns.appendChild(cx.allocator, check_cell);
        row.name_cell = try ui.box(cx, S.column(self.name_width), .{});
        try row.name_cell.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get(if (entry.kind == .directory) "folder" else if (entry.kind == .symlink) "file-symlink" else "file").?, if (entry.kind == .directory) S.theme.current().accent else S.theme.current().fg_2, S.icon(16)));
        var full_size_buffer: [64]u8 = undefined;
        const full_size = if (entry.kind == .directory) "目录" else if (entry.size) |size| try std.fmt.bufPrint(&full_size_buffer, "{d} B", .{size}) else "大小未知";
        const detail = try std.fmt.allocPrint(cx.allocator, "{s}\n{s}\n{s} · {s}", .{ entry.display_name, entry.absolute_path, full_size, if (entry.modified_full.len > 0) entry.modified_full else if (entry.modified_label.len > 0) entry.modified_label else "修改时间未知" });
        defer cx.allocator.free(detail);
        const tooltip_text = try scope.createText(detail, .{});
        const tooltip = try ui.widgets.Tooltip(.{ .text = tooltip_text, .open = row.tooltip_open, .open_delay_ms = @as(f32, 450) }).mount(scope, cx);
        for (tooltip.content.children.items) |label_| if (label_.getText()) |current| {
            var multiline = current;
            multiline.wrap = .word;
            label_.setText(multiline);
        };
        tooltip.wrapper.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0, .height = .{ .px = S.row_height } });
        tooltip.trigger.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = S.row_height }, .min_width = 0, .direction = .row, .align_items = .center, .overflow = .hidden });
        const name = try label(cx, tooltip.trigger, S.filename, entry.display_name);
        name.meta.ownership.meta.test_id = "files.row.name";
        name.setStyleInline(cx.allocator, S.flexible());
        try row.name_cell.appendChild(cx.allocator, tooltip.wrapper);
        try row.columns.appendChild(cx.allocator, row.name_cell);
        row.name_cell.meta.ownership.meta.test_id = "files.row.drag";
        row.name_cell.setStyleInline(cx.allocator, .{ .hit_behavior = .@"opaque" });
        row.drag_binding = try drag.Binding.attach(scope, cx, row.name_cell, .{ .can_start = Row.dragCanStart }, Row.dragged, row);
        row.name_cell.behavior.events.on_event_capture = Row.nameCapture;
        row.name_cell.behavior.events.capture_context = row;
        var size_buffer: [64]u8 = undefined;
        const size_text = if (entry.kind == .directory or parentEntry(entry)) "—" else if (entry.size) |size| try formatSize(&size_buffer, size) else "未知";
        const size = try label(cx, row.columns, S.numeric, size_text);
        size.setStyleInline(cx.allocator, .{ .width = .{ .px = self.size_width }, .flex_shrink = 0 });
        size.meta.ownership.meta.test_id = "files.row.size";
        const date = try label(cx, row.columns, S.secondary, entry.modified_label);
        date.setStyleInline(cx.allocator, .{ .width = .{ .px = self.date_width }, .flex_shrink = 0 });
        date.meta.ownership.meta.test_id = "files.row.modified";
        try scope.createEffect(row, Row.paint);
        return node;
    }
};

const Control = struct {
    const ControlKind = enum { new_folder, refresh, context, back, parent, history, submit_path, sort, transfer, recover };
    pane: *Pane,
    kind: ControlKind,
    column: u2 = 0,
    fn run(self: *Control) void {
        self.perform() catch |err| self.pane.report(err);
    }
    fn perform(self: *Control) !void {
        const p = self.pane.projection() orelse return;
        const selection: Selection = .{ .keys = p.selected_keys, .anchor = p.anchor, .focused_key = p.focused_key };
        switch (self.kind) {
            .submit_path => self.pane.submitPath(),
            .back => if (p.navigation_enabled and p.can_back) {
                try self.pane.emit(.back);
            },
            .parent => if (p.navigation_enabled and p.can_parent and !std.mem.eql(u8, p.resolved_path, "/")) {
                try self.pane.emit(.parent);
            },
            .history => if (p.navigation_enabled) {
                try self.pane.emit(.history);
            },
            .refresh => try self.pane.emit(.refresh),
            .recover => try self.pane.emit(.recover),
            .context => try self.pane.emit(.{ .context = selection }),
            .new_folder => if (fresh(p) and p.writable and p.can_mkdir) {
                try self.pane.emit(.new_folder);
            },
            .sort => try self.pane.emit(.{ .sort = .{ .column = @fromBackingInt(@intCast(self.column)), .descending = if (@backingInt(p.sort.column) == self.column) !p.sort.descending else false } }),
            .transfer => {
                const destination = self.pane.view.source.?.value.panes[1 - @backingInt(self.pane.side)];
                if (fresh(p) and p.can_transfer and p.selected_keys.len > 0 and fresh(destination) and destination.writable) try self.pane.emit(.{ .transfer = .{ .selection = selection, .destination = destination.stamp, .directory = destination.resolved_path } });
            },
        }
    }
};
const Row = struct {
    pane: *Pane,
    stamp: Stamp,
    key: []const u8,
    node: *ui.Node,
    columns: *ui.Node,
    name_cell: *ui.Node,
    checked: *ui.Signal(bool),
    style: *ui.Signal(S.ButtonStyle),
    tooltip_open: *ui.Signal(bool),
    modifiers: ui.events.Modifiers = .{},
    drag_binding: ?*drag.Binding = null,
    fn current(self: *Row) ?PaneProjection {
        if (self.pane.view.pending != null) return null;
        const p = self.pane.rowProjection() orelse return null;
        if (!std.meta.eql(self.stamp, p.stamp) or entryIndex(p.entries, self.key) == null) return null;
        return p;
    }
    fn paint(self: *Row) void {
        _ = self.pane.paint.get();
        const p = self.current() orelse return;
        const selected = contains(p.selected_keys, self.key);
        self.checked.set(selected);
        const hovering = self.pane.view.drop_side == self.pane.side and std.mem.eql(u8, self.pane.view.drop_path[0..self.pane.view.drop_path_len], self.key);
        self.style.set(S.fileRow(self.pane.column_width, selected or hovering, sameOptional(p.focused_key, self.key)));
        self.columns.setStyleInline(self.pane.view.cx.allocator, .{ .width = .{ .px = self.pane.column_width } });
        self.name_cell.setStyleInline(self.pane.view.cx.allocator, .{ .width = .{ .px = self.pane.name_width } });
        if (self.columns.children.items.len >= 4) {
            self.columns.children.items[2].setStyleInline(self.pane.view.cx.allocator, .{ .width = .{ .px = self.pane.size_width } });
            const date = self.columns.children.items[3];
            date.setDisplay(if (self.pane.date_width == 0) .none else .flex);
            date.setStyleInline(self.pane.view.cx.allocator, .{ .width = .{ .px = self.pane.date_width } });
            const entry = p.entries[entryIndex(p.entries, self.key).?];
            const full = entry.modified_label;
            const shown = if (self.pane.date_width < 140 and full.len >= 16 and full[4] == '-') full[5..16] else full;
            date.setTextContent(self.pane.view.cx.allocator, shown) catch {};
        }
    }
    fn clicked(self: *Row) void {
        self.choose(self.modifiers, false) catch |err| self.pane.report(err);
        self.modifiers = .{};
    }
    fn check(self: *Row, _: bool) void {
        self.choose(.{ .super = true }, false) catch |err| self.pane.report(err);
    }
    fn choose(self: *Row, mods: ui.events.Modifiers, context: bool) !void {
        const p = self.current() orelse return error.StaleFileProjection;
        const index = entryIndex(p.entries, self.key).?;
        if (parentEntry(p.entries[index])) return;
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(self.pane.view.cx.allocator);
        const a = self.pane.view.cx.allocator;
        if (context and contains(p.selected_keys, self.key)) {
            try keys.appendSlice(a, p.selected_keys);
        } else if (mods.shift and p.anchor != null and entryIndex(p.entries, p.anchor.?) != null) {
            const anchor = entryIndex(p.entries, p.anchor.?).?;
            for (p.entries[@min(index, anchor) .. @max(index, anchor) + 1]) |entry| if (!parentEntry(entry)) {
                try keys.append(a, entry.absolute_path);
            };
        } else if (ui.events.primaryModifier(mods)) {
            for (p.selected_keys) |key| if (!std.mem.eql(u8, key, self.key)) {
                try keys.append(a, key);
            };
            if (!contains(p.selected_keys, self.key)) try keys.append(a, self.key);
        } else try keys.append(a, self.key);
        const selected: Selection = .{ .keys = keys.items, .anchor = if (mods.shift) p.anchor else self.key, .focused_key = self.key };
        try self.pane.emit(if (context) .{ .context = selected } else .{ .selection = selected });
    }
    fn open(self: *Row) !void {
        const p = self.current() orelse return error.StaleFileProjection;
        const entry = p.entries[entryIndex(p.entries, self.key).?];
        if (p.navigation_enabled and entry.kind == .directory) try self.pane.emit(.{ .navigate = .{ .requested_path = entry.absolute_path, .base_directory = p.resolved_path } });
    }
    fn move(self: *Row, delta: i32, mods: ui.events.Modifiers) !void {
        const p = self.current() orelse return error.StaleFileProjection;
        const index = entryIndex(p.entries, self.key).?;
        const next: usize = @intCast(std.math.clamp(@as(i64, @intCast(index)) + delta, 0, @as(i64, @intCast(p.entries.len)) - 1));
        const entry = p.entries[next];
        if (mods.shift) {
            var temporary = self.*;
            temporary.key = entry.absolute_path;
            try temporary.choose(mods, false);
        } else try self.pane.emit(.{ .selection = .{ .keys = p.selected_keys, .anchor = p.anchor, .focused_key = entry.absolute_path } });
        ui.widgets.virtual_list.ensureVisible(self.pane.virtual, self.pane.virtualIndex(p, next));
        self.pane.focus_requested = true;
    }
    fn nameCapture(event_: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Row = @ptrCast(@alignCast(raw.?));
        switch (event_) {
            .click => |click_event| {
                if (click_event.click_count < 2) self.choose(click_event.modifiers, false) catch |err| self.pane.report(err);
                return .stop;
            },
            .double_click => {
                self.open() catch |err| self.pane.report(err);
                return .stop;
            },
            else => return .ignored,
        }
    }
    fn dragCanStart(_: drag.StartRequest, raw: *anyopaque) bool {
        const self: *Row = @ptrCast(@alignCast(raw));
        const p = self.current() orelse return false;
        const at = entryIndex(p.entries, self.key) orelse return false;
        return fresh(p) and p.can_transfer and !parentEntry(p.entries[at]);
    }
    fn dragged(event_: drag.Event, raw: *anyopaque) void {
        const self: *Row = @ptrCast(@alignCast(raw));
        const view = self.pane.view;
        switch (event_.phase) {
            .start => {
                self.tooltip_open.set(false);
                const p = self.current() orelse return;
                if (!contains(p.selected_keys, self.key)) self.choose(event_.start_modifiers, false) catch |err| {
                    self.pane.report(err);
                    if (self.drag_binding) |binding| binding.cancel(.explicit);
                    return;
                };
                view.beginDrag(self) catch |err| {
                    self.pane.report(err);
                    if (self.drag_binding) |binding| binding.cancel(.explicit);
                    return;
                };
                view.hoverDrag(event_.position_window);
            },
            .move => view.hoverDrag(event_.position_window),
            .end => {
                view.finishDrag(event_.position_window) catch |err| self.pane.report(err);
            },
            .cancel => {
                view.clearDrag();
            },
        }
    }
    fn event(event_: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Row = @ptrCast(@alignCast(raw.?));
        switch (event_) {
            .focus => self.tooltip_open.set(true),
            .blur => self.tooltip_open.set(false),
            .mouse_down => |e| {
                self.modifiers = e.modifiers;
                if (e.button == .right) {
                    self.choose(e.modifiers, true) catch |err| self.pane.report(err);
                    return .stop;
                }
            },
            .click => |e| {
                // The second click belongs to directory activation. Emitting a
                // redundant selection ack here would queue a projection before
                // the framework's immediately following double_click event.
                if (e.click_count >= 2) return .stop;
                self.modifiers = e.modifiers;
            },
            .double_click => {
                self.open() catch |err| self.pane.report(err);
                return .stop;
            },
            .key_down => |e| {
                switch (e.key) {
                    .escape => {
                        self.tooltip_open.set(false);
                    },
                    .@"return" => self.open() catch |err| self.pane.report(err),
                    .space => self.choose(.{ .super = true }, false) catch |err| self.pane.report(err),
                    .up => self.move(-1, e.modifiers) catch |err| self.pane.report(err),
                    .down => self.move(1, e.modifiers) catch |err| self.pane.report(err),
                    .a => if (ui.events.primaryModifier(e.modifiers)) {
                        self.pane.selectAll(true);
                    } else return .ignored,
                    .c => if (ui.events.primaryModifier(e.modifiers)) {
                        const p = self.current() orelse return .stop;
                        self.pane.emit(.{ .copy_paths = .{ .keys = p.selected_keys, .anchor = p.anchor, .focused_key = p.focused_key } }) catch |err| self.pane.report(err);
                    } else return .ignored,
                    else => return .ignored,
                }
                return .stop;
            },
            else => {},
        }
        return .ignored;
    }
};

fn label(cx: *ui.Cx, parent_: *ui.Node, comptime style: anytype, text: []const u8) !*ui.Node {
    const node = try ui.textStyled(cx, style, "");
    try node.setTextContent(cx.allocator, text);
    try parent_.appendChild(cx.allocator, node);
    return node;
}
fn fresh(p: PaneProjection) bool {
    return p.state == .ready or p.state == .empty;
}
fn absolute(path: []const u8) bool {
    return path.len > 0 and path[0] == '/' and std.mem.indexOfScalar(u8, path, 0) == null;
}
fn parentEntry(entry: Entry) bool {
    return std.mem.eql(u8, entry.raw_name, "..");
}
fn entryIndex(entries: []const Entry, key: []const u8) ?usize {
    for (entries, 0..) |entry, i| if (std.mem.eql(u8, entry.absolute_path, key)) return i;
    return null;
}
fn contains(keys: []const []const u8, key: []const u8) bool {
    for (keys) |value| if (std.mem.eql(u8, value, key)) return true;
    return false;
}
fn sameOptional(key: ?[]const u8, value: []const u8) bool {
    return if (key) |k| std.mem.eql(u8, k, value) else false;
}
fn sameRows(a: PaneProjection, b: PaneProjection) bool {
    if (!std.meta.eql(a.stamp, b.stamp) or a.entries.len != b.entries.len) return false;
    for (a.entries, b.entries) |x, y| {
        if (!std.mem.eql(u8, x.absolute_path, y.absolute_path) or !std.mem.eql(u8, x.display_name, y.display_name) or x.kind != y.kind or x.size != y.size or !std.mem.eql(u8, x.modified_label, y.modified_label)) return false;
    }
    return true;
}
fn validate(source: Projection) !void {
    if (source.revision == 0 or @backingInt(source.owner.session_id) == 0 or source.owner.generation == 0) return error.InvalidFileProjection;
    for (source.panes, 0..) |p, i| {
        if (!source.owner.eql(p.stamp.owner) or p.stamp.endpoint.binding_id == 0 or p.stamp.endpoint.binding_generation == 0 or p.stamp.request_id == 0 or p.stamp.directory_revision == 0 or p.selection_revision == 0 or !absolute(p.resolved_path)) return error.InvalidFileProjection;
        if ((i == 0 and p.stamp.endpoint.kind != .local_fs) or (i == 1 and p.stamp.endpoint.kind != .sftp) or p.entries.len > 100_000 or p.selected_keys.len > p.entries.len) return error.InvalidFileProjection;
        var seen: std.StringHashMap(void) = .init(std.heap.page_allocator);
        defer seen.deinit();
        for (p.entries) |entry| {
            if (!absolute(entry.absolute_path) or entry.raw_name.len == 0 or std.mem.indexOfScalar(u8, entry.raw_name, 0) != null) return error.InvalidFileProjection;
            const result = try seen.getOrPut(entry.absolute_path);
            if (result.found_existing) return error.DuplicateFileKey;
        }
    }
}
fn isDescendant(parent_: *ui.Node, child: *ui.Node) bool {
    var current: ?*ui.Node = child;
    while (current) |value| {
        if (value == parent_) return true;
        current = value.parent;
    }
    return false;
}
fn findRow(node: *ui.Node, key: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |id| if (std.mem.eql(u8, id, "files.row")) {
        if (node.behavior.interaction.a11y) |info| if (info.label) |value| if (std.mem.eql(u8, value, key)) return node;
    };
    for (node.children.items) |child| if (findRow(child, key)) |found| return found;
    return null;
}
fn formatSize(buffer: []u8, size: u64) ![]const u8 {
    if (size < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{size});
    if (size < 1024 * 1024) return std.fmt.bufPrint(buffer, "{d:.1} KiB", .{@as(f64, @floatFromInt(size)) / 1024});
    if (size < 1024 * 1024 * 1024) return std.fmt.bufPrint(buffer, "{d:.1} MiB", .{@as(f64, @floatFromInt(size)) / (1024 * 1024)});
    return std.fmt.bufPrint(buffer, "{d:.1} GiB", .{@as(f64, @floatFromInt(size)) / (1024 * 1024 * 1024)});
}

fn within(rect: anytype, point: drag.Point) bool {
    return point.x >= rect.x and point.y >= rect.y and point.x < rect.x + rect.w and point.y < rect.y + rect.h;
}
fn rowAt(node: *ui.Node, point: drag.Point) ?*ui.Node {
    if (node.style.display == .none) return null;
    if (node.meta.ownership.meta.test_id) |id| if (std.mem.eql(u8, id, "files.row") and within(node.globalRect(), point)) return node;
    for (node.children.items) |child| if (rowAt(child, point)) |result| return result;
    return null;
}

fn matchesFilter(entry: Entry, query: []const u8) bool {
    if (query.len == 0) return true;
    // Byte-preserving ASCII case folding also keeps non-ASCII names intact.
    if (query.len > entry.display_name.len) return false;
    for (0..entry.display_name.len - query.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(entry.display_name[start..][0..query.len], query)) return true;
    }
    return false;
}
