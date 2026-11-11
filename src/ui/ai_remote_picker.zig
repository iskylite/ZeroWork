//! Inline resource selection. All IO stays with the original FileBindingHost.
const std = @import("std");
const ui = @import("ui");
const files = @import("../host/file_binding_host.zig");
const capture = @import("../host/ai_remote_file_snapshot.zig");
const attachments = @import("../ai/local_text_attachments.zig");
const scope_mod = @import("../ai/tool_scope.zig");
const S = @import("ai_remote_picker_styles.zig");
/// Own the filename content while retaining native Button focus and events.
pub fn filenameButton(scope: *ui.Scope, cx: *ui.Cx, name: []const u8, on_click: ?ui.Handler(void), visible: ?*ui.Signal(bool)) !struct { button: *ui.Node, label: *ui.Node } {
    const button_node = try ui.widgets.Button(.{ .a11y_label = name, .variant = .ghost, .base_style = try S.theme.paintSignal(S.ButtonStyle, cx, scope, S.option, .{}), .hover_style = try S.theme.paintSignal(?S.ButtonStyle, cx, scope, S.hover, .{}), .on_click = on_click }).mount(scope, cx);
    const label = try ui.textStyled(cx, S.filename, name);
    label.setStyleInline(cx.allocator, S.filenameLabel());
    label.meta.ownership.meta.test_id = "ai.remote.filename";
    const hint = try @import("control_hint.zig").mount(cx, scope, label, name, .{ .id = "ai.remote.filename.tooltip", .width = 360, .wrap = .char, .visible = visible, .focus_target = button_node, .layout = S.filenameLabel() });
    try button_node.appendChild(cx.allocator, hint.wrapper);
    return .{ .button = button_node, .label = label };
}
pub const Source = struct { session: @import("../host/identity.zig").SessionHandle, name: []const u8, cwd: []const u8, available: bool };
pub const Callbacks = struct {
    context: *anyopaque,
    overlay_owner: ?*ui.Node = null,
    ensure: *const fn (*anyopaque, Source) anyerror!files.Bindings,
    live: *const fn (*anyopaque, scope_mod.Owner) ?scope_mod.Scope,
    stage: *const fn (*anyopaque, scope_mod.Owner, *attachments.ContentRef) anyerror!void,
    attach: ?*const fn (*anyopaque, scope_mod.Owner, *attachments.ContentRef) anyerror!void = null,
};
const Active = struct { reader: *capture.Reader, context: capture.Context, delivered: bool = false };
const Row = struct {
    view: *View,
    index: usize,
    revision: u64,
    fn check(self: *Row, _: bool) void {
        self.choose();
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
    source_options: *ui.Signal([]const ui.widgets.SelectOption) = undefined,
    source_value: *ui.Signal(?[]const u8) = undefined,
    source_hint_label: *ui.Node = undefined,
    source_items: [16]ui.widgets.SelectOption = undefined,
    source_ids: [16][4]u8 = undefined,
    status: *ui.Node = undefined,
    feedback: *ui.Node = undefined,
    empty: *ui.Node = undefined,
    list_node: *ui.Node = undefined,
    read_disabled: *ui.Signal(bool) = undefined,
    attach_disabled: *ui.Signal(bool) = undefined,
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
    want_attach: bool = false,
    readers: std.ArrayList(Active) = .empty,
    want_list: bool = false,
    want_read: bool = false,
    open_state: bool = false,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, host: *files.FileBindingHost, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .host = host, .callbacks = callbacks, .path = try scope.createText("", .{}), .filter = try scope.createText("", .{}), .count = try scope.createSignal(usize, 0), .version = try scope.createSignal(u64, 0) });
        self.root = try ui.box(cx, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 } }, .{});
        self.modal_open = try scope.createSignal(bool, false);
        const modal = try ui.widgets.Modal(.{ .managed_focus = self.callbacks.overlay_owner == null, .open = self.modal_open, .width = 760, .max_height = 438, .background = S.theme.current().overlay, .on_open_change = cx.on(View, self, modalChanged) }).mount(scope, cx);
        if (self.callbacks.overlay_owner) |owner| {
            _ = try @import("scoped_modal.zig").bind(cx, scope, modal, .{ .owner = .{ .node = owner } });
        } else if (!modal.portaled) if (cx.root) |root| try root.appendChild(cx.allocator, modal.overlay);
        modal.dialog.meta.ownership.meta.test_id = "ai.remote.picker";
        self.surface = modal.body;
        const scoped = self.callbacks.overlay_owner != null;
        self.surface.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = if (scoped) 6 else 8, .padding = ui.Padding.all(if (scoped) 16 else 20) });
        const heading = try ui.boxStyled(cx, S.row, .{});
        heading.setStyleInline(cx.allocator, .{ .gap = 8 });
        const title_icon = try S.theme.icon(cx, ui.icons.file_search, "accent_ink", .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
        title_icon.meta.ownership.meta.test_id = "ai.remote.title.icon";
        try heading.appendChild(cx.allocator, title_icon);
        try heading.appendChild(cx.allocator, try ui.textStyled(cx, S.heading, "引用远程文件"));
        try heading.appendChild(cx.allocator, try ui.box(cx, .{ .width = .fill() }, .{}));
        const close_button = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.x, .icon_size = 14, .a11y_label = "关闭远程文件选择器", .variant = .ghost, .size = .sm, .base_style = try S.theme.paintSignal(S.ButtonStyle, cx, scope, S.closeButton, .{}), .hover_style = try S.theme.paintSignal(?S.ButtonStyle, cx, scope, S.hover, .{}), .on_click = cx.on(View, self, close) }).mount(scope, cx);
        close_button.meta.ownership.meta.test_id = "ai.remote.close";
        const close_hint = try @import("control_hint.zig").mount(cx, scope, close_button, "关闭远程文件选择器", .{ .id = "ai.remote.close.tooltip", .visible = self.modal_open });
        try heading.appendChild(cx.allocator, close_hint.wrapper);
        try self.surface.appendChild(cx.allocator, heading);
        const path_row = try ui.boxStyled(cx, S.row, .{});
        path_row.setStyleInline(cx.allocator, .{ .height = .{ .px = 32 } });
        self.source_options = try scope.createList(ui.widgets.SelectOption, &.{});
        self.source_value = try scope.createSignal(?[]const u8, null);
        const source_picker = try ui.widgets.Select(.{ .options = self.source_options, .value = self.source_value, .width = 180, .dropdown_width = 320, .size = .md, .on_change = cx.on(View, self, sourceChanged) }).mount(scope, cx);
        source_picker.trigger.meta.ownership.meta.test_id = "ai.remote.source";
        source_picker.trigger.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
        source_picker.wrapper.setStyleInline(cx.allocator, .{ .width = .{ .px = 180 }, .min_width = 0, .flex_shrink = 1 });
        const source_hint = try @import("control_hint.zig").mount(cx, scope, source_picker.wrapper, "远程来源", .{ .id = "ai.remote.source.tooltip", .visible = self.modal_open, .focus_target = source_picker.trigger.parent.?, .width = 320 });
        self.source_hint_label = source_hint.content.children.items[0];
        var source_hint_text = self.source_hint_label.getText().?;
        source_hint_text.wrap = .char;
        self.source_hint_label.setText(source_hint_text);
        try path_row.appendChild(cx.allocator, source_hint.wrapper);
        const home_button = try self.button("主目录", "ai.remote.home", ui.icons.get("house").?, home);
        const home_hint = try @import("control_hint.zig").mount(cx, scope, home_button, "返回主目录", .{ .id = "ai.remote.home.tooltip", .visible = self.modal_open });
        try path_row.appendChild(cx.allocator, home_hint.wrapper);
        const parent_button = try self.button("上级目录", "ai.remote.parent", ui.icons.get("arrow-up").?, parent);
        const parent_hint = try @import("control_hint.zig").mount(cx, scope, parent_button, "返回上级目录", .{ .id = "ai.remote.parent.tooltip", .visible = self.modal_open });
        try path_row.appendChild(cx.allocator, parent_hint.wrapper);
        var input = try ui.widgets.Input(.{ .value = self.path, .placeholder = "输入远程目录，例如 /var/log", .on_change = cx.on(View, self, pathChanged), .on_submit = cx.on(View, self, pathSubmitted) }).mountResult(scope, cx);
        @import("app_theme.zig").styleInput(input);
        input.input_container.setStyleInline(cx.allocator, S.input());
        @import("ai_composer_controls_styles.zig").tuneInput(&input);
        input.node.meta.ownership.meta.test_id = "ai.remote.path";
        input.node.setStyleInline(cx.allocator, .{ .min_width = 0, .flex = 1, .flex_shrink = 1 });
        self.input_state = input.state;
        try path_row.appendChild(cx.allocator, input.node);
        const go_button = try self.button("打开目录", "ai.remote.go", ui.icons.get("arrow-right").?, go);
        const go_hint = try @import("control_hint.zig").mount(cx, scope, go_button, "打开目录（Enter）", .{ .id = "ai.remote.go.tooltip", .visible = self.modal_open });
        try path_row.appendChild(cx.allocator, go_hint.wrapper);
        try self.surface.appendChild(cx.allocator, path_row);
        var filter = try ui.widgets.Input(.{ .value = self.filter, .placeholder = "筛选当前目录的文件名…", .on_change = cx.on(View, self, filterChanged) }).mountResult(scope, cx);
        @import("app_theme.zig").styleInput(filter);
        filter.input_container.setStyleInline(cx.allocator, S.input());
        @import("ai_composer_controls_styles.zig").tuneInput(&filter);
        filter.node.meta.ownership.meta.test_id = "ai.remote.filter";
        try self.surface.appendChild(cx.allocator, filter.node);
        const list = try ui.widgets.VirtualList(.{ .item_count = self.count, .data_version = self.version, .item_height = 43, .height = 129, .overscan = 1 }).rows(self, renderRow).viewMount(scope, cx);
        list.root.?.setStyleInline(cx.allocator, S.list());
        list.root.?.meta.ownership.meta.test_id = "ai.remote.directory";
        const table = try ui.boxStyled(cx, S.table, .{});
        const columns = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 29 }, .direction = .row, .align_items = .center, .padding = .{ .left = 32, .right = 8 }, .gap = 8, .flex_shrink = 0 }, .{});
        const name_heading = try ui.textStyled(cx, S.text, "名称");
        name_heading.setStyleInline(cx.allocator, .{ .width = .fill() });
        try columns.appendChild(cx.allocator, name_heading);
        for ([_][]const u8{ "大小", "修改时间（UTC）" }, 0..) |name, column| {
            const label = try ui.textStyled(cx, S.text, name);
            label.setStyleInline(cx.allocator, .{ .width = .{ .px = if (column == 0) 80 else 134 } });
            try columns.appendChild(cx.allocator, label);
        }
        try table.appendChild(cx.allocator, columns);
        self.list_node = list.root.?;
        try table.appendChild(cx.allocator, self.list_node);
        const empty_box = try ui.boxStyled(cx, S.empty, .{});
        self.empty = try ui.textStyled(cx, S.text, "正在连接远程文件服务…");
        self.empty.meta.ownership.meta.test_id = "ai.remote.empty";
        try empty_box.appendChild(cx.allocator, self.empty);
        try table.appendChild(cx.allocator, empty_box);
        try self.surface.appendChild(cx.allocator, table);
        const footer = try ui.boxStyled(cx, S.row, .{});
        footer.setStyleInline(cx.allocator, .{ .height = .{ .px = 32 } });
        self.read_disabled = try scope.createSignal(bool, true);
        self.attach_disabled = try scope.createSignal(bool, true);
        const info_button = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.get("info").?, .icon_size = 16, .a11y_label = "文件信息", .variant = .ghost, .size = .sm, .base_style = try S.theme.paintSignal(S.ButtonStyle, cx, scope, S.navigationButton, .{}), .hover_style = try S.theme.paintSignal(?S.ButtonStyle, cx, scope, S.hover, .{}) }).mount(scope, cx);
        info_button.meta.ownership.meta.test_id = "ai.remote.info";
        const info_hint = try @import("control_hint.zig").mount(cx, scope, info_button, "未选择文件\n附加仅引用来源和路径；预览读取文本，最多 4 KiB。", .{ .id = "ai.remote.info.tooltip", .visible = self.modal_open, .width = 280 });
        self.status = info_hint.content.children.items[0];
        self.status.meta.ownership.meta.test_id = "ai.remote.status";
        try footer.appendChild(cx.allocator, info_hint.wrapper);
        self.feedback = try ui.textStyled(cx, S.feedback, "");
        self.feedback.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
        self.feedback.meta.ownership.meta.test_id = "ai.remote.feedback";
        try footer.appendChild(cx.allocator, self.feedback);
        const preview = try ui.widgets.Button(.{ .label = "预览文件", .variant = .secondary, .size = .sm, .base_style = try S.theme.paintSignal(S.ButtonStyle, cx, scope, S.button, .{}), .disabled = self.read_disabled, .on_click = cx.on(View, self, readSelected) }).mount(scope, cx);
        preview.meta.ownership.meta.test_id = "ai.remote.read";
        try footer.appendChild(cx.allocator, preview);
        const attach = try ui.widgets.Button(.{ .label = "附加文件", .variant = .primary, .size = .sm, .base_style = try S.theme.paintSignal(S.ButtonStyle, cx, scope, S.primary, .{}), .disabled = self.attach_disabled, .on_click = cx.on(View, self, attachSelected) }).mount(scope, cx);
        try @import("app_theme.zig").stylePrimary(cx, scope, attach, self.attach_disabled);
        attach.meta.ownership.meta.test_id = "ai.remote.attach";
        try footer.appendChild(cx.allocator, attach);
        try self.surface.appendChild(cx.allocator, footer);
        return self;
    }
    fn modalChanged(self: *View, value: bool) void {
        if (!value and self.open_state) self.close();
    }
    fn button(self: *View, label: []const u8, id: []const u8, asset: ui.SvgAsset, comptime handler: *const fn (*View) void) !*ui.Node {
        const button_node = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = asset, .icon_size = 16, .a11y_label = label, .variant = .secondary, .size = .sm, .base_style = try S.theme.paintSignal(S.ButtonStyle, self.cx, self.scope, S.navigationButton, .{}), .hover_style = try S.theme.paintSignal(?S.ButtonStyle, self.cx, self.scope, S.hover, .{}), .on_click = self.cx.on(View, self, handler) }).mount(self.scope, self.cx);
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
        self.source_index = 0;
        for (self.sources[0..self.source_count], 0..) |source, index| if (source.available) {
            self.source_index = index;
            break;
        };
        self.source_value.set(if (self.source_count > 0) self.source_items[self.source_index].value else null);
        try self.source_hint_label.setTextContent(self.cx.allocator, "远程来源");
        self.open_state = true;
        self.modal_open.set(true);
        if (self.source_count == 0) return self.message("当前范围没有可读远程来源");
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
        self.want_attach = false;
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
        try self.source_hint_label.setTextContent(self.cx.allocator, source.name);
        const initial_path = if (source.cwd.len != 0) source.cwd else ".";
        self.path.set(initial_path);
        _ = self.input_state.setText(initial_path);
        self.filter.set("");
        if (!source.available) return self.message("来源已离线，无法读取");
        self.bindings = try self.callbacks.ensure(self.callbacks.context, source);
        self.want_list = true;
        try self.message(if (source.cwd.len == 0) "正在读取远程主目录…" else "正在读取终端当前目录…");
    }
    fn pathChanged(self: *View, _: []const u8) void {
        self.invalidate();
        self.want_list = false;
        self.want_read = false;
        self.message("目录已修改，尚未读取") catch {};
    }
    fn pathSubmitted(self: *View, _: []const u8) void {
        self.go();
    }
    fn home(self: *View) void {
        self.path.set(".");
        _ = self.input_state.setText(".");
        self.go();
    }
    fn filterChanged(self: *View, _: []const u8) void {
        self.applyFilter() catch |err| self.fail(err);
    }
    fn go(self: *View) void {
        if (!std.mem.eql(u8, self.path.peek(), ".")) capture.validatePath(self.path.peek()) catch {
            self.message("请输入以 / 开头的远程目录，例如 /var/log") catch {};
            return;
        };
        self.invalidate();
        self.want_list = true;
        self.want_read = false;
        self.message("正在读取目录…") catch {};
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
        self.want_attach = true;
        self.want_read = false;
        self.want_list = false;
        self.showFeedback("正在附加引用…") catch {};
        self.cx.requestRedraw();
    }
    fn attachReferences(self: *View) !void {
        const owner = self.owner orelse return error.StaleOwner;
        const live = self.callbacks.live(self.callbacks.context, owner) orelse return error.StaleOwner;
        const source = self.sources[self.source_index];
        _ = try live.validate(&.{@backingInt(source.session.session_id)});
        const attach = self.callbacks.attach orelse return error.AttachmentUnavailable;
        for (self.selections.items) |path| {
            var reference = try attachments.ContentRef.createRemoteReference(self.cx.allocator, source.session, source.name, path);
            defer reference.release();
            try attach(self.callbacks.context, owner, &reference);
        }
        self.close();
    }
    fn readSelected(self: *View) void {
        if (self.selections.items.len != 1) {
            self.message("请先选择文件") catch {};
            return;
        }
        self.want_read = true;
        self.want_list = false;
        self.showFeedback("正在读取预览…") catch {};
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
                if (self.liveContext(active.context) != null) self.accept(result) catch |err| self.fail(err);
            }
            if (active.reader.cleanupReceipt() == .released and active.reader.retired) {
                try active.reader.deinit();
                _ = self.readers.orderedRemove(index);
                continue;
            }
            index += 1;
        }
        if (self.open_state and self.want_attach and self.readers.items.len == 0) {
            self.want_attach = false;
            self.attachReferences() catch |err| self.fail(err);
        }
        if (self.open_state and (self.want_list or self.want_read) and self.readers.items.len == 0) {
            const bindings = self.bindings orelse return;
            const state = self.host.state(bindings.directory) orelse {
                self.stopPendingRead();
                return self.showFeedback("文件来源连接已关闭，请重新选择来源");
            };
            if (state.phase == .failed or state.phase == .cleanup_unknown) {
                self.stopPendingRead();
                return self.showFeedback("远程文件连接失败，请重新选择来源");
            }
            if (state.phase == .ready) {
                const live = self.callbacks.live(self.callbacks.context, self.owner.?) orelse {
                    self.close();
                    return;
                };
                const context: capture.Context = .{ .scope = live, .source = .{ .session = self.sources[self.source_index].session, .revision = self.revision, .bindings = bindings } };
                self.readers.ensureUnusedCapacity(self.cx.allocator, 1) catch |err| {
                    self.fail(err);
                    return;
                };
                const reader = capture.Reader.start(self.cx.allocator, self.host, context, if (self.want_read) self.selected.? else self.path.peek(), if (self.want_read) .{ .read = .{} } else .{ .list = .{} }) catch |err| {
                    self.fail(err);
                    return;
                };
                self.readers.appendAssumeCapacity(.{ .reader = reader, .context = context });
                if (self.want_read) try self.showFeedback("正在读取预览…") else try self.message("读取目录…");
                self.want_list = false;
                self.want_read = false;
            }
        }
        self.updateActions();
        if (self.readers.items.len != 0 or self.want_list or self.want_read or self.want_attach) self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }
    fn accept(self: *View, result: capture.ResultRef) !void {
        const value = result.value().?;
        switch (value.body) {
            .failure => |failure| {
                self.stopPendingRead();
                const reason = switch (failure) {
                    .remote => |remote| switch (remote) {
                        .not_found => "目录或文件不存在，请检查路径",
                        .permission_denied => "没有权限读取此目录或文件",
                        .unsupported_binary => "无法预览 ISO 等二进制文件，可附加路径引用",
                        .unsupported_encoding => "无法预览：文件不是有效的 UTF-8 文本",
                        .not_regular_file => "此项不是可读取的普通文件",
                        .connection => "远程文件连接已断开，请重新选择来源",
                        .subsystem_denied => "远程服务器拒绝 SFTP 服务，无法读取文件",
                        .already_exists => "远程服务器报告文件已存在，读取失败",
                        .unsupported => "远程服务器不支持此文件读取操作",
                        .path_limit => "远程路径过长，无法读取",
                        .entry_limit => "远程目录条目超出读取上限",
                        .source_changed => "文件在读取期间发生变化，请重新读取",
                        .timeout => "远程读取超时，请重试",
                        .close_failed => "远程文件关闭失败，请重新连接",
                        .out_of_memory => "内存不足，无法读取文件",
                        .protocol => "远程文件服务返回了无效数据，请重新连接",
                    },
                    .cancelled => "远程读取已取消",
                    .source_changed => "文件来源已变化，请重新选择文件",
                    .out_of_memory => "内存不足，无法读取文件",
                    .protocol => "远程文件读取结果无效，请重新读取",
                };
                try self.showFeedback(reason);
            },
            .listing => |listing| {
                self.listing.release();
                self.listing = result.retain();
                if (value.metadata.actual_path) |actual_path| {
                    self.path.set(actual_path);
                    _ = self.input_state.setText(actual_path);
                }
                try self.applyFilter();
                const details = try std.fmt.allocPrint(self.cx.allocator, "{s} · {d} 项", .{ if (listing.entries.len == 0) "目录为空" else if (listing.truncated) "目录已截断 · 最多 256 项" else "未选择文件", listing.entries.len });
                defer self.cx.allocator.free(details);
                try self.message(details);
            },
            .text => {
                var reference = try attachments.ContentRef.createRemote(self.cx.allocator, result, self.sources[self.source_index].name);
                defer reference.release();
                try self.callbacks.stage(self.callbacks.context, self.owner.?, &reference);
                self.close();
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
        if (self.listing.value() != null) {
            if (self.filtered_count == 0) try self.message(if (self.filter.peek().len != 0) "没有匹配的文件，请修改筛选条件" else "此目录为空，可以返回上级或输入其他目录") else try self.selectionMessage();
        }
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
        const container = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 43 }, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .left = 8, .right = 8 }, .background = if (selected) S.theme.popupSelection() else ui.Color.TRANSPARENT, .flex_shrink = 0 }, .{});
        if (selected) container.meta.per_frame.hooks.on_theme = selectedTheme;
        const checked = try scope.createSignal(bool, selected);
        const checkbox = if (entry.attributes.kind == .file) try ui.widgets.Checkbox(.{ .checked = ui.split(checked, cx.on(Row, row, Row.check)), .box_size = @as(f32, 14), .label = "" }).mount(scope, cx) else try ui.box(cx, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 }, .{});
        checkbox.meta.ownership.meta.test_id = "ai.remote.entry";
        try container.appendChild(cx.allocator, checkbox);
        const icon = if (entry.attributes.kind == .directory) try S.theme.icon(cx, ui.icons.folder, "fg_2", .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }) else try ui.iconTint(cx, @import("file_workspace_icons.zig").asset(entry.display_name), @import("file_workspace_icons.zig").color(entry.display_name), .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } });
        try container.appendChild(cx.allocator, icon);
        const filename = try filenameButton(scope, cx, entry.display_name, cx.on(Row, row, Row.choose), self.modal_open);
        const button_node = filename.button;
        button_node.meta.ownership.meta.test_id = "ai.remote.preview";
        const name_cell = try ui.box(cx, .{ .width = .fill(), .min_width = 0, .direction = .row, .align_items = .center }, .{});
        try name_cell.appendChild(cx.allocator, button_node);
        try container.appendChild(cx.allocator, name_cell);
        var size_buffer: [40]u8 = undefined;
        const size_text = if (entry.attributes.kind == .directory) "—" else if (entry.attributes.size) |size| try std.fmt.bufPrint(&size_buffer, "{d} B", .{size}) else "—";
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
        self.want_attach = false;
        self.want_read = false;
        if (self.selected) |previous| self.cx.allocator.free(previous);
        self.selected = try self.cx.allocator.dupe(u8, path);
        for (self.selections.items, 0..) |chosen, selected_index| if (std.mem.eql(u8, chosen, path)) {
            self.cx.allocator.free(self.selections.orderedRemove(selected_index));
            self.version.set(self.version.peek() +| 1);
            self.cx.allocator.free(self.selected.?);
            self.selected = if (self.selections.items.len > 0) try self.cx.allocator.dupe(u8, self.selections.items[self.selections.items.len - 1]) else null;
            try self.selectionMessage();
            return;
        };
        const copy = try self.cx.allocator.dupe(u8, path);
        errdefer self.cx.allocator.free(copy);
        try self.selections.append(self.cx.allocator, copy);
        self.version.set(self.version.peek() +| 1);
        try self.selectionMessage();
    }
    fn selectionMessage(self: *View) !void {
        var buffer: [96]u8 = undefined;
        try self.message(if (self.selections.items.len > 0) try std.fmt.bufPrint(&buffer, "已选择 {d} 个文件", .{self.selections.items.len}) else try std.fmt.bufPrint(&buffer, "{d} 个项目 · 未选择文件", .{self.filtered_count}));
    }
    fn updateActions(self: *View) void {
        const busy = self.want_list or self.want_read or self.want_attach or self.readers.items.len != 0;
        self.read_disabled.set(busy or self.selections.items.len != 1);
        self.attach_disabled.set(busy or self.selections.items.len == 0 or self.callbacks.attach == null);
    }
    fn message(self: *View, value: []const u8) !void {
        try self.feedback.setTextContent(self.cx.allocator, "");
        const help = try std.fmt.allocPrint(self.cx.allocator, "{s}\n附加仅引用来源和路径；预览读取文本，最多 4 KiB。", .{value});
        defer self.cx.allocator.free(help);
        try self.status.setTextContent(self.cx.allocator, help);
        const no_entries = self.filtered_count == 0;
        self.list_node.setDisplay(if (no_entries) .none else .flex);
        self.empty.parent.?.setDisplay(if (no_entries) .flex else .none);
        if (no_entries) try self.empty.setTextContent(self.cx.allocator, value);
        self.updateActions();
        self.cx.requestRedraw();
    }
    fn showFeedback(self: *View, value: []const u8) !void {
        try self.message(value);
        if (self.filtered_count > 0) try self.feedback.setTextContent(self.cx.allocator, value);
    }
    fn stopPendingRead(self: *View) void {
        self.want_attach = false;
        self.want_list = false;
        self.want_read = false;
    }
    fn fail(self: *View, err: anyerror) void {
        self.stopPendingRead();
        self.showFeedback(switch (err) {
            error.StaleOwner, error.StaleRemoteSource, error.TargetOutsideAssistant, error.TargetNotAuthorized => "远程来源已失效，请重新选择来源",
            error.OutOfMemory => "内存不足，无法附加或预览文件",
            error.RemotePathTooLong => "远程路径过长，无法附加或预览文件",
            error.InvalidRemotePath => "远程路径无效，请重新选择文件",
            error.AttachmentUnavailable => "附加功能不可用，请重新打开文件选择器",
            else => @errorName(err),
        }) catch {};
    }
    pub fn release(self: *View) error{Busy}!void {
        if (self.readers.items.len != 0) return error.Busy;
        self.readers.deinit(self.cx.allocator);
        self.selections.deinit(self.cx.allocator);
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

fn selectedTheme(node: *ui.Node, _: *const ui.ThemeTokens, _: std.mem.Allocator) void {
    node.setBackground(S.theme.popupSelection());
}
