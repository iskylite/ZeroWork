//! Draft-only repair for known-version payloads with damaged bookmark records.
const std = @import("std");
const ui = @import("ui");
const bookmarks = @import("bookmarks.zig");
const editor = @import("editor.zig");
const S = @import("editor_styles.zig");

const Actions = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, []const bookmarks.RepairInput) anyerror!void,
    cancel: *const fn (*anyopaque) void,
};

pub const Panel = struct {
    cx: *ui.Cx,
    arena: std.heap.ArenaAllocator,
    actions: Actions,
    root: *ui.Node,
    rows: []Row,
    active: ?*Row = null,
    details: *ui.Node = undefined,
    raw: *ui.Node = undefined,
    name: *ui.Signal([]const u8) = undefined,
    address: *ui.Signal([]const u8) = undefined,
    name_error: *ui.Signal([]const u8) = undefined,
    url_error: *ui.Signal([]const u8) = undefined,
    row_disabled: *ui.Signal(bool) = undefined,
    apply_disabled: *ui.Signal(bool) = undefined,
    notice: *ui.Node = undefined,

    fn cleanup(self: *Panel) void {
        for (self.rows) |row| {
            if (row.owned_name) |bytes| self.cx.allocator.free(bytes);
            if (row.owned_url) |bytes| self.cx.allocator.free(bytes);
        }
        self.arena.deinit();
    }

    fn setNotice(self: *Panel, message: []const u8) void {
        self.notice.setTextContent(self.cx.allocator, message) catch return;
        self.cx.requestRedraw();
    }

    fn refresh(self: *Panel) void {
        var inputs: [bookmarks.max_count]bookmarks.RepairInput = undefined;
        const chosen = self.collect(&inputs) catch |err| {
            self.apply_disabled.set(true);
            if (err == error.BookmarkCapacity) {
                var count: usize = 0;
                for (self.rows) |row| {
                    if (row.kept) count += 1;
                }
                var buffer: [144]u8 = undefined;
                const message = std.fmt.bufPrint(&buffer, "最多保留 {d} 个书签，请移除 {d} 个。", .{ bookmarks.max_count, count - bookmarks.max_count }) catch unreachable;
                self.setNotice(message);
            } else self.setNotice("请检查有问题的书签后应用修复。");
            return;
        };
        var scratch = std.heap.ArenaAllocator.init(self.cx.allocator);
        defer scratch.deinit();
        _ = bookmarks.applyRepair(scratch.allocator(), chosen) catch |err| {
            self.apply_disabled.set(true);
            self.setNotice(if (err == error.DuplicateBookmarkUrl) "网址重复，请编辑或移除重复的书签。" else "请检查有问题的书签后应用修复。");
            return;
        };
        self.apply_disabled.set(self.active != null);
        var buffer: [72]u8 = undefined;
        self.setNotice(std.fmt.bufPrint(&buffer, "{d} / {d}", .{ chosen.len, bookmarks.max_count }) catch unreachable);
    }

    fn collect(self: *const Panel, buffer: *[bookmarks.max_count]bookmarks.RepairInput) ![]const bookmarks.RepairInput {
        var count: usize = 0;
        for (self.rows) |row| {
            if (!row.kept) continue;
            if (count < buffer.len) buffer[count] = row.input;
            count += 1;
        }
        if (count > buffer.len) return error.BookmarkCapacity;
        for (self.rows) |row| {
            if (row.kept and row.review_required) return error.BookmarkRepairRequired;
        }
        return buffer[0..count];
    }

    fn show(self: *Panel, row: *Row) !void {
        if (!row.kept) return;
        if (self.active) |previous| previous.summary.setDisplay(.flex);
        try row.node.appendChild(self.cx.allocator, self.details);
        self.active = row;
        self.name.set(row.input.title);
        self.address.set(row.input.url);
        try self.raw.setTextContent(self.cx.allocator, row.raw);
        self.raw.setDisplay(if (row.raw.len == 0 or !row.review_required) .none else .flex);
        row.summary.setDisplay(.none);
        self.details.setDisplay(.flex);
        self.validateRow();
        self.refresh();
    }

    fn closeRow(self: *Panel) void {
        const row = self.active orelse return;
        self.cx.setFocus(null);
        self.details.setDisplay(.none);
        if (row.kept) row.summary.setDisplay(.flex);
        self.active = null;
        self.refresh();
    }

    fn removeRow(self: *Panel) void {
        if (self.active) |row| row.remove();
    }

    fn fieldChanged(self: *Panel, _: []const u8) void {
        self.validateRow();
    }

    fn validateRow(self: *Panel) void {
        self.name_error.set("");
        self.url_error.set("");
        self.row_disabled.set(false);
        var scratch = std.heap.ArenaAllocator.init(self.cx.allocator);
        defer scratch.deinit();
        _ = bookmarks.applyRepair(scratch.allocator(), &.{.{
            .id = .{ .bytes = @splat(1) },
            .title = self.name.peek(),
            .url = self.address.peek(),
        }}) catch |err| {
            self.row_disabled.set(true);
            if (err == error.InvalidBookmarkTitle) {
                self.name_error.set("请输入有效的书签名称。");
            } else if (err == error.OutOfMemory) {
                self.setNotice("无法校验书签，请重试。");
            } else {
                self.url_error.set("请输入有效的 HTTP(S) 网址。");
            }
        };
    }

    pub fn applyRow(self: *Panel) void {
        const row = self.active orelse return;
        self.validateRow();
        if (self.row_disabled.peek()) return;
        row.update(self.name.peek(), self.address.peek()) catch {
            self.setNotice("无法应用书签修改，请重试。");
            return;
        };
        self.closeRow();
    }

    pub fn apply(self: *Panel) void {
        if (self.apply_disabled.peek()) return;
        var inputs: [bookmarks.max_count]bookmarks.RepairInput = undefined;
        const chosen = self.collect(&inputs) catch return;
        self.actions.apply(self.actions.context, chosen) catch {
            self.setNotice("无法应用书签修复，请检查修改后重试。");
        };
    }

    fn cancel(self: *Panel) void {
        self.actions.cancel(self.actions.context);
    }
};

const Row = struct {
    panel: *Panel,
    input: bookmarks.RepairInput,
    owned_name: ?[]u8 = null,
    owned_url: ?[]u8 = null,
    raw: []const u8,
    node: *ui.Node,
    summary: *ui.Node,
    title: *ui.Node,
    subtitle: *ui.Node,
    kept: bool = true,
    review_required: bool,

    fn edit(self: *Row) void {
        self.panel.show(self) catch self.panel.setNotice("无法编辑此书签，请重试。");
    }

    pub fn remove(self: *Row) void {
        if (!self.kept) return;
        self.kept = false;
        if (self.panel.active == self) self.panel.closeRow();
        self.node.setDisplay(.none);
        self.panel.refresh();
    }

    fn update(self: *Row, name: []const u8, address: []const u8) !void {
        const a = self.panel.cx.allocator;
        const new_name = try a.dupe(u8, name);
        errdefer a.free(new_name);
        const new_url = try a.dupe(u8, address);
        errdefer a.free(new_url);
        try self.title.setTextContent(a, name);
        try self.subtitle.setTextContent(a, address);
        if (self.owned_name) |old| a.free(old);
        if (self.owned_url) |old| a.free(old);
        self.owned_name = new_name;
        self.owned_url = new_url;
        self.input.title = new_name;
        self.input.url = new_url;
        self.review_required = false;
    }
};

pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, damaged: []const bookmarks.RepairRow, actions: Actions) !*Panel {
    const root = try ui.boxStyled(cx, S.layout, .{});
    root.meta.ownership.meta.test_id = "web.bookmark.repair";
    try parent.appendChild(cx.allocator, root);
    const self = try scope.createState(Panel, .{ .cx = cx, .arena = .init(cx.allocator), .actions = actions, .root = root, .rows = &.{} });
    scope.onCleanup(Panel, self, Panel.cleanup) catch |err| {
        self.cleanup();
        return err;
    };
    const a = self.arena.allocator();
    self.apply_disabled = try scope.createSignal(bool, true);
    self.row_disabled = try scope.createSignal(bool, true);

    self.notice = try ui.textStyled(cx, S.feedback, "");
    self.notice.meta.ownership.meta.test_id = "web.bookmark.capacity";
    self.notice.setStyleInline(cx.allocator, .{ .margin = .{ .left = 24, .right = 24, .top = 12, .bottom = 6 }, .flex_shrink = 0 });
    try root.appendChild(cx.allocator, self.notice);
    const scroll = try ui.widgets.ScrollArea(.{ .rubber_band_y = false }).mount(scope, cx);
    scroll.container.setStyleInline(cx.allocator, S.wizard.scroll());
    scroll.container.meta.ownership.meta.test_id = "web.bookmark.list";
    try root.appendChild(cx.allocator, scroll.container);
    const body = try ui.boxStyled(cx, S.body, .{});
    try scroll.content.appendChild(cx.allocator, body);

    self.details = try ui.boxStyled(cx, S.wizard.card, .{});
    self.details.setDisplay(.none);
    try body.appendChild(cx.allocator, self.details);
    self.raw = try ui.textStyled(cx, S.feedback, "");
    self.raw.setDisplay(.none);
    try self.details.appendChild(cx.allocator, self.raw);
    self.name = try scope.createText("", .{});
    self.address = try scope.createText("", .{});
    self.name_error = try scope.createText("", .{});
    self.url_error = try scope.createText("", .{});
    const name_field = try editor.labeled(cx, self.details, "名称");
    try editor.textField(cx, scope, name_field, self.name, self.name_error, "", "web.bookmark.repair.name", cx.on(Panel, self, Panel.fieldChanged));
    const url_field = try editor.labeled(cx, self.details, "网址");
    try editor.textField(cx, scope, url_field, self.address, self.url_error, "", "web.bookmark.repair.url", cx.on(Panel, self, Panel.fieldChanged));
    const edit_footer = try ui.box(cx, S.wizard.row(34), .{});
    try self.details.appendChild(cx.allocator, edit_footer);
    try editor.actionButton(cx, scope, edit_footer, "移除", "web.bookmark.repair.remove", false, .{ .value = false }, cx.on(Panel, self, Panel.removeRow));
    try edit_footer.appendChild(cx.allocator, try ui.spacer(cx));
    try editor.actionButton(cx, scope, edit_footer, "取消", "web.bookmark.repair.cancel_row", false, .{ .value = false }, cx.on(Panel, self, Panel.closeRow));
    try editor.actionButton(cx, scope, edit_footer, "应用", "web.bookmark.repair.apply_row", false, .{ .signal = self.row_disabled }, cx.on(Panel, self, Panel.applyRow));

    const rows = try a.alloc(Row, damaged.len);
    self.rows = rows[0..0];
    var first_editable: ?*Row = null;
    for (damaged, rows, 0..) |entry, *row, i| {
        const number = entry.row_id + 1;
        const name = entry.originalString("title") orelse "";
        const address = entry.originalString("url") orelse "";
        const raw = if (entry.issues.invalid_record) try std.json.Stringify.valueAlloc(a, entry.raw, .{}) else "";
        const node = try ui.boxStyled(cx, S.field, .{});
        node.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "web.bookmark.row.{d}", .{number});
        try body.appendChild(cx.allocator, node);
        const summary = try ui.box(cx, S.wizard.row(50), .{});
        try node.appendChild(cx.allocator, summary);
        const copy = try ui.boxStyled(cx, S.field, .{});
        copy.setStyleInline(cx.allocator, .{ .flex = 1, .flex_shrink = 1 });
        try summary.appendChild(cx.allocator, copy);
        const title = try ui.text(cx, if (name.len != 0) name else "书签名称无效", clippedText(13, 600));
        const subtitle = try ui.text(cx, if (raw.len != 0) raw else address, clippedText(12, 400));
        try copy.appendChild(cx.allocator, title);
        try copy.appendChild(cx.allocator, subtitle);
        row.* = .{
            .panel = self,
            .input = .{ .id = if (entry.originalString("id")) |id| bookmarks.Id.parse(id) catch null else null, .title = name, .url = address },
            .raw = raw,
            .node = node,
            .summary = summary,
            .title = title,
            .subtitle = subtitle,
            .review_required = entry.issues.invalid_record or entry.issues.invalid_title or entry.issues.invalid_url,
        };
        self.rows = rows[0 .. i + 1];
        if (first_editable == null and row.review_required and !entry.issues.invalid_record) first_editable = row;
        if (entry.raw == .object) try editor.actionButton(cx, scope, summary, "编辑", try std.fmt.allocPrint(a, "web.bookmark.edit.{d}", .{number}), false, .{ .value = false }, cx.on(Row, row, Row.edit));
        try editor.actionButton(cx, scope, summary, "移除", try std.fmt.allocPrint(a, "web.bookmark.remove.{d}", .{number}), false, .{ .value = false }, cx.on(Row, row, Row.remove));
    }

    const footer = try ui.boxStyled(cx, S.footer, .{});
    try root.appendChild(cx.allocator, footer);
    try footer.appendChild(cx.allocator, try ui.spacer(cx));
    try editor.actionButton(cx, scope, footer, "取消", "web.bookmark.repair.cancel", false, .{ .value = false }, cx.on(Panel, self, Panel.cancel));
    try editor.actionButton(cx, scope, footer, "应用修复", "web.bookmark.apply", true, .{ .signal = self.apply_disabled }, cx.on(Panel, self, Panel.apply));
    if (first_editable) |row| try self.show(row) else self.refresh();
    return self;
}

fn clippedText(size: f32, weight: u16) ui.TextStyle {
    var style = S.wizard.text(size, weight, false);
    style.text_overflow = .ellipsis;
    return style;
}
