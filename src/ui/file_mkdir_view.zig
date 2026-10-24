//! One frozen card's literal child-name draft. No transfer or shell action.
const std = @import("std");
const ui = @import("ui");
const Files = @import("file_workspace_view.zig");
const Controller = @import("../host/file_workspace_controller.zig");
const operations = @import("../host/operation.zig");
const Name = @import("../host/directory_name.zig");
const S = @import("file_mkdir_styles.zig");
const FS = @import("file_workspace_styles.zig");

const Frozen = struct { arena: std.heap.ArenaAllocator, envelope: Files.Envelope, directory: []const u8, badge: []const u8 };
pub const View = struct {
    cx: *ui.Cx,
    pane: *Files.Pane,
    model: *Controller.Controller,
    raw: *ui.Signal([]const u8),
    create_disabled: *ui.Signal(bool),
    editor: *ui.Node = undefined,
    result: *ui.Node = undefined,
    input: ui.widgets.input.InputResult = undefined,
    heading: *ui.Node = undefined,
    path: *ui.Node = undefined,
    feedback: *ui.Node = undefined,
    create: *ui.Node = undefined,
    create_wrapper: *ui.Node = undefined,
    cancel: *ui.Node = undefined,
    frozen: ?Frozen = null,
    operation: ?operations.OperationKey = null,
    shown: bool = false,
    phase: ?Controller.MkdirPhase = null,
    failure: ?Controller.MkdirFailure = null,
    local_error: ?anyerror = null,
    focus_pending: bool = false,
    locate_pending: bool = false,
    last_revision: u64 = 0,
    last_clip_height: f32 = -1,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, pane: *Files.Pane, model: *Controller.Controller) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .pane = pane, .model = model, .raw = try scope.createText("", .{}), .create_disabled = try scope.createSignal(bool, true) });
        try scope.onCleanup(View, self, cleanup);
        self.editor = try ui.boxStyled(cx, S.editor, .{});
        self.editor.meta.ownership.meta.test_id = "files.mkdir.editor";
        self.editor.behavior.events.on_key_down = onKey;
        self.editor.behavior.events.key_context = self;
        try self.editor.appendChild(cx.allocator, try ui.box(cx, FS.column(24), .{}));
        const name = try ui.boxStyled(cx, S.name, .{});
        try self.editor.appendChild(cx.allocator, name);
        try name.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.folder, S.theme.current().accent, FS.icon(16)));
        const field = try ui.boxStyled(cx, S.field, .{});
        field.meta.ownership.meta.test_id = "files.mkdir.field";
        try name.appendChild(cx.allocator, field);
        self.input = try ui.widgets.Input(.{ .value = self.raw, .placeholder = "新建文件夹", .growable = true, .embedded = true, .on_submit = cx.on(View, self, submitted), .on_change = cx.on(View, self, changed) }).mountResult(scope, cx);
        S.tune(&self.input);
        self.input.input_container.meta.ownership.meta.test_id = "files.mkdir.name";
        self.input.input_container.behavior.interaction.a11y.?.label = "文件夹名称";
        try field.appendChild(cx.allocator, self.input.node);
        inline for (.{ @as(f32, 76), @as(f32, 140) }) |width| {
            const dash = try ui.textStyled(cx, FS.secondary, "—");
            dash.setStyleInline(cx.allocator, .{ .width = .{ .px = width }, .flex_shrink = 0 });
            try self.editor.appendChild(cx.allocator, dash);
        }
        self.result = try ui.boxStyled(cx, S.result, .{});
        self.result.meta.ownership.meta.test_id = "files.mkdir.result";
        self.result.behavior.events.on_key_down = onKey;
        self.result.behavior.events.key_context = self;
        self.heading = try label(cx, self.result, S.heading, "files.mkdir.heading");
        self.path = try label(cx, self.result, S.path, "files.mkdir.path");
        self.feedback = try label(cx, self.result, FS.secondary, "files.mkdir.feedback");
        const actions = try ui.box(cx, S.actions(), .{});
        try self.result.appendChild(cx.allocator, actions);
        self.cancel = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = @as(f32, 16), .a11y_label = "取消当前操作", .base_style = S.button(), .on_click = cx.on(View, self, dismiss) }).mount(scope, cx);
        self.cancel.meta.ownership.meta.test_id = "files.mkdir.cancel";
        try actions.appendChild(cx.allocator, try tooltip(cx, scope, self.cancel, "取消当前操作"));
        self.create = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.folder_plus, .icon_size = @as(f32, 16), .a11y_label = "创建文件夹", .base_style = S.button(), .disabled = self.create_disabled, .on_click = cx.on(View, self, submit) }).mount(scope, cx);
        self.create.meta.ownership.meta.test_id = "files.mkdir.create";
        self.create_wrapper = try tooltip(cx, scope, self.create, "创建文件夹");
        try actions.appendChild(cx.allocator, self.create_wrapper);
        try pane.installDraft(self.editor, self.result);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    pub fn open(self: *View, envelope: Files.Envelope) !void {
        if (self.pending()) return error.MkdirPending;
        const projection = self.model.projection() orelse return error.FileProjectionUnavailable;
        const pane = projection.panes[@backingInt(envelope.side)];
        if (envelope.side != self.pane.side or envelope.action != .new_folder or !std.meta.eql(pane.stamp, envelope.stamp) or envelope.projection_revision != projection.revision or envelope.selection_revision != pane.selection_revision) return error.StaleFileAction;
        if (!pane.writable or !pane.can_mkdir or !fresh(pane)) return error.DirectoryNotWritable;
        if (self.shown) return;
        var arena = std.heap.ArenaAllocator.init(self.cx.allocator);
        errdefer arena.deinit();
        const directory = try arena.allocator().dupe(u8, pane.resolved_path);
        const badge = try arena.allocator().dupe(u8, pane.badge);
        if (self.frozen) |*old| old.arena.deinit();
        self.frozen = .{ .arena = arena, .envelope = envelope, .directory = directory, .badge = badge };
        self.raw.set("");
        self.operation = null;
        self.phase = null;
        self.failure = null;
        self.local_error = null;
        self.shown = true;
        self.focus_pending = true;
        self.last_revision = 0;
        self.last_clip_height = -1;
        try self.paint();
    }
    /// Called at Presentation.safeTick, after real service receipts and before
    /// layout. A hidden form never reopens itself when a late result arrives.
    pub fn sync(self: *View) !void {
        if (self.frozen == null or self.last_revision == self.model.revision) return;
        self.last_revision = self.model.revision;
        if (self.operation) |key| if (self.model.mkdirStatus(self.pane.side)) |status| {
            if (status.key.eql(key) and std.meta.eql(status.stamp, self.frozen.?.envelope.stamp)) {
                const before = self.phase;
                self.phase = status.phase;
                self.failure = if (status.phase == .failed and !std.mem.eql(u8, status.name, self.raw.peek())) null else status.failure;
                if (status.phase == .succeeded and before != .succeeded and self.shown) self.locate_pending = true;
            }
        };
        if (self.shown) try self.paint();
    }
    fn hasError(self: *const View, err: anyerror) bool {
        return if (self.local_error) |value| value == err else false;
    }
    fn pending(self: *const View) bool {
        return self.phase == .creating or self.phase == .refreshing;
    }
    fn current(self: *View) ?Files.Envelope {
        const original = self.frozen orelse return null;
        const projection = self.model.projection() orelse return null;
        if (self.model.closing or !projection.owner.eql(original.envelope.stamp.owner)) return null;
        const pane = projection.panes[@backingInt(self.pane.side)];
        if (!std.meta.eql(pane.stamp, original.envelope.stamp) or !std.mem.eql(u8, pane.resolved_path, original.directory) or !pane.writable or !pane.can_mkdir or !fresh(pane)) return null;
        var envelope = original.envelope;
        envelope.projection_revision = projection.revision;
        envelope.selection_revision = pane.selection_revision;
        return envelope;
    }
    fn changed(self: *View, _: []const u8) void {
        if (self.pending()) return;
        self.local_error = null;
        self.failure = null;
        self.paint() catch {};
    }
    fn submitted(self: *View, _: []const u8) void {
        self.submit();
    }
    fn submit(self: *View) void {
        if (!self.shown or self.pending() or self.input.state.imeIsComposing() or self.phase == .succeeded or self.phase == .created_refresh_failed) return;
        const envelope = self.current() orelse {
            self.local_error = error.StaleDirectory;
            self.paint() catch {};
            return;
        };
        Name.validate(self.raw.peek()) catch |err| {
            self.local_error = err;
            self.paint() catch {};
            return;
        };
        const pane = self.model.projection().?.panes[@backingInt(self.pane.side)];
        for (pane.entries) |entry| if (std.mem.eql(u8, entry.raw_name, self.raw.peek())) {
            self.local_error = error.AlreadyExists;
            self.paint() catch {};
            return;
        };
        const key = self.model.mkdir(envelope, self.raw.peek()) catch |err| {
            self.local_error = err;
            self.paint() catch {};
            return;
        };
        self.operation = key;
        self.phase = .creating;
        self.failure = null;
        self.local_error = null;
        self.paint() catch {};
    }
    pub fn dismiss(self: *View) void {
        if (!self.shown) return;
        self.shown = false;
        self.focus_pending = false;
        self.locate_pending = false;
        if (self.cx.focused_node) |node| if (descendant(self.editor, node) or descendant(self.result, node)) self.cx.clearFocus();
        self.pane.setDraft(false, false);
    }
    fn paint(self: *View) !void {
        const original = self.frozen orelse return;
        const name = self.raw.peek();
        const readonly = self.pending() or self.phase == .succeeded or self.phase == .created_refresh_failed;
        self.input.state.readonly = readonly;
        self.input.input_container.behavior.interaction.a11y.?.readonly = readonly;
        self.input.state.dirty = true;
        var invalid = false;
        Name.validate(name) catch {
            invalid = true;
        };
        const duplicate = self.hasError(error.AlreadyExists) or self.failure == .already_exists;
        self.create_disabled.set(readonly or invalid or duplicate or self.current() == null);
        const create_visible = self.phase != .succeeded and self.phase != .created_refresh_failed and self.phase != .stale;
        self.create.setDisplay(if (create_visible) .flex else .none);
        self.create_wrapper.setDisplay(if (create_visible) .flex else .none);
        const editing = self.phase != .succeeded and self.phase != .created_refresh_failed;
        self.pane.setDraft(editing, true);
        var title_buffer: [512]u8 = undefined;
        var target_buffer: [8192]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buffer, "{s}{s}{s}{s}", .{ original.directory, if (std.mem.endsWith(u8, original.directory, "/")) @as([]const u8, "") else "/", name, if (name.len == 0) @as([]const u8, "") else "/" });
        try self.path.setTextContent(self.cx.allocator, target);
        var title: []const u8 = "";
        var feedback: []const u8 = "Enter 创建 · Esc 取消";
        var danger = false;
        if (self.phase == .succeeded) {
            title = try std.fmt.bufPrint(&title_buffer, "已创建 {s}", .{name});
            feedback = "目录已刷新";
        } else if (self.phase == .created_refresh_failed) {
            title = "目录已创建，列表刷新失败";
            feedback = "请重新读取原目录";
            danger = true;
        } else if (self.phase == .creating) {
            title = "正在创建目录…";
            feedback = "等待创建结果";
        } else if (self.phase == .refreshing) {
            title = "目录已创建，正在刷新…";
            feedback = "等待目录列表";
        } else if (duplicate) {
            title = try std.fmt.bufPrint(&title_buffer, "名称已存在 · {s}", .{name});
            feedback = "请修改名称";
            danger = true;
        } else if (self.failure) |failure| {
            title = try std.fmt.bufPrint(&title_buffer, "创建失败 · {s}", .{failureText(failure)});
            feedback = "名称已保留，可修改或重试";
            danger = true;
        } else if (self.hasError(error.InvalidName)) {
            title = "文件夹名称无效";
            feedback = "名称不能为空，不能为 . 或 ..，不能包含路径分隔符";
            danger = true;
        } else if (self.phase == .stale or self.current() == null or self.hasError(error.StaleDirectory)) {
            title = "原目录已变化";
            feedback = "请在当前目录重新打开新建操作";
            self.create_disabled.set(true);
            danger = true;
        } else if (self.local_error) |err| {
            title = try std.fmt.bufPrint(&title_buffer, "创建失败 · {s}", .{@errorName(err)});
            danger = true;
        } else title = try std.fmt.bufPrint(&title_buffer, "新建{s}文件夹{s}{s}", .{ if (self.pane.side == .local) @as([]const u8, "本地") else "远程", if (self.pane.side == .remote and original.badge.len > 0) @as([]const u8, " · ") else "", if (self.pane.side == .remote) original.badge else "" });
        try self.heading.setTextContent(self.cx.allocator, title);
        try self.feedback.setTextContent(self.cx.allocator, feedback);
        self.heading.setTextColor(if (danger) S.theme.current().danger_ink else if (self.phase == .succeeded) S.theme.current().ok_ink else S.theme.current().fg_1);
        self.feedback.setTextColor(if (danger) S.theme.current().danger_ink else S.theme.current().fg_2);
        self.cx.requestRedraw();
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.shown) return .done;
        var relayout = false;
        if (self.pane.draft_open) {
            const height = self.pane.data_clip.globalRect().h;
            if (@abs(height - self.last_clip_height) > 0.01) {
                self.last_clip_height = height;
                relayout = self.pane.revealDraft();
            }
        }
        if (self.focus_pending and self.editor.globalRect().w > 0) {
            self.focus_pending = false;
            self.cx.setFocus(self.input.input_container);
        }
        if (self.locate_pending and self.pane.view.pending == null) {
            self.locate_pending = false;
            if (self.model.mkdirStatus(self.pane.side)) |status| self.pane.locate(status.path);
        }
        return if (relayout) .needs_layout else .done;
    }
    fn onKey(key: ui.events.KeyCode, _: ui.events.Modifiers, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        if (key != .escape or self.input.state.imeIsComposing()) return .ignored;
        self.dismiss();
        return .stop;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.frozen) |*value| value.arena.deinit();
    }
};
fn fresh(pane: Files.PaneProjection) bool {
    return pane.state == .ready or pane.state == .empty;
}
fn descendant(parent: *ui.Node, child: *ui.Node) bool {
    var node: ?*ui.Node = child;
    while (node) |current| : (node = current.parent) if (current == parent) return true;
    return false;
}
fn label(cx: *ui.Cx, parent: *ui.Node, comptime style: anytype, id: []const u8) !*ui.Node {
    const node = try ui.textStyled(cx, style, "");
    node.meta.ownership.meta.test_id = id;
    node.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0, .overflow = .hidden });
    try parent.appendChild(cx.allocator, node);
    return node;
}
fn failureText(failure: Controller.MkdirFailure) []const u8 {
    return switch (failure) {
        .already_exists => "名称已存在",
        .permission_denied => "Permission denied",
        .not_found => "目录不存在",
        .timeout => "请求超时",
        .cancelled => "请求已取消",
        .unavailable => "连接不可用",
        .protocol => "目录响应无效",
        .io => "文件操作失败",
    };
}

fn tooltip(cx: *ui.Cx, scope: *ui.Scope, node: *ui.Node, text: []const u8) !*ui.Node {
    const result = try ui.widgets.Tooltip(.{ .text = text, .open_delay_ms = @as(f32, 450) }).mount(scope, cx);
    result.wrapper.setStyleInline(cx.allocator, S.tooltip());
    try result.trigger.appendChild(cx.allocator, node);
    return result.wrapper;
}
