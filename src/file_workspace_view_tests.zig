//! Native Cx layout/hit tests, immutable directory fixtures, no filesystem or SSH IO.
const std = @import("std");
const ui = @import("ui");
const files = @import("ui/file_workspace_view.zig");
const a = std.testing.allocator;
const owner = @import("host/identity.zig").SessionHandle{ .session_id = @fromBackingInt(301), .generation = 7 };
const entries = [_]files.Entry{
    .{ .absolute_path = "/tmp", .raw_name = "..", .display_name = "..", .kind = .directory },
    .{ .absolute_path = "/tmp/fixture/project", .raw_name = "project", .display_name = "project", .kind = .directory, .modified_label = "10-20 09:10" },
    .{ .absolute_path = "/tmp/fixture/alpha.txt", .raw_name = "alpha.txt", .display_name = "alpha.txt", .kind = .file, .size = 1024, .modified_label = "10-20 09:12" },
    .{ .absolute_path = "/tmp/fixture/beta.txt", .raw_name = "beta.txt", .display_name = "beta.txt", .kind = .file, .size = 0, .modified_label = "10-20 09:14" },
    .{ .absolute_path = "/tmp/fixture/unknown.bin", .raw_name = "unknown.bin", .display_name = "unknown.bin", .kind = .file },
};
fn source() files.Projection {
    return .{ .revision = 1, .owner = owner, .panes = .{
        .{ .stamp = .{ .owner = owner, .endpoint = .{ .kind = .local_fs, .binding_id = 1, .binding_generation = 1 }, .request_id = 1, .directory_revision = 1 }, .title = "本地目录", .subtitle = "本机文件", .badge = "本机", .resolved_path = "/tmp/fixture", .entries = &entries, .writable = true, .can_transfer = true },
        .{ .stamp = .{ .owner = owner, .endpoint = .{ .kind = .sftp, .binding_id = 7, .binding_generation = 2 }, .request_id = 1, .directory_revision = 1 }, .title = "测试服务器", .subtitle = "SFTP · #301", .badge = "SFTP #301", .resolved_path = "/srv/fixture", .state = .empty, .writable = true, .can_mkdir = true, .can_transfer = true },
    } };
}
const Record = struct {
    tag: std.meta.Tag(files.Action) = .refresh,
    stamp: files.Stamp = undefined,
    selection_revision: u64 = 0,
    keys: [16][512]u8 = undefined,
    lengths: [16]usize = @splat(0),
    count: usize = 0,
    path: [1024]u8 = undefined,
    path_len: usize = 0,
    destination: ?files.Stamp = null,
};
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *files.View,
    calls: usize = 0,
    record: Record = .{},
    auto_ack: bool = false,
    fn init(self: *Fixture, width: f32, height: f32) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .view = undefined };
        self.cx.setViewport(width, height);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.view = try files.View.mount(self.cx, self.scope, .{ .context = self, .action = action });
        try self.cx.root.?.appendChild(a, self.view.root);
        try self.view.update(source());
        self.settle();
    }
    fn deinit(self: *Fixture) void {
        self.cx.clearFocus();
        self.scope.dispose();
        self.cx.deinit();
    }
    fn current(self: *Fixture) files.Projection {
        return .{ .revision = self.view.source.?.value.revision, .owner = owner, .panes = .{ self.view.panes[0].projection().?, self.view.panes[1].projection().? } };
    }
    fn action(raw: *anyopaque, envelope: files.Envelope) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.record = .{ .tag = envelope.action, .stamp = envelope.stamp, .selection_revision = envelope.selection_revision };
        const selection: ?files.Selection = switch (envelope.action) {
            .selection, .context, .copy_paths => |value| value,
            .transfer => |value| value.selection,
            else => null,
        };
        if (selection) |value| {
            self.record.count = value.keys.len;
            for (value.keys, 0..) |key, i| {
                self.record.lengths[i] = key.len;
                @memcpy(self.record.keys[i][0..key.len], key);
            }
        }
        const path = switch (envelope.action) {
            .navigate => |value| value.requested_path,
            .transfer => |value| value.directory,
            else => "",
        };
        self.record.path_len = path.len;
        @memcpy(self.record.path[0..path.len], path);
        if (envelope.action == .transfer) self.record.destination = envelope.action.transfer.destination;
        if (self.auto_ack and envelope.action == .selection) {
            var value = self.current();
            value.revision += 1;
            const pane = &value.panes[@backingInt(envelope.side)];
            pane.selection_revision += 1;
            pane.selected_keys = envelope.action.selection.keys;
            pane.anchor = envelope.action.selection.anchor;
            pane.focused_key = envelope.action.selection.focused_key;
            try self.view.update(value);
        }
    }
    fn settle(self: *Fixture) void {
        self.cx.setTestFrameStep(16) catch unreachable;
        for (0..12) |_| {
            self.cx.frame_count += 1;
            self.cx.advanceFrameClock();
            _ = self.cx.render();
        }
    }
    fn click(self: *Fixture, target: *ui.Node, mods: ui.events.Modifiers) void {
        const r = target.globalRect();
        self.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, mods);
        self.cx.handleMouseUpEx(r.x + r.w / 2, r.y + r.h / 2, .left, mods);
        self.settle();
    }
    fn node(self: *Fixture, side: files.Side, id: []const u8) *ui.Node {
        return find(self.view.panes[@backingInt(side)].root, id) orelse @panic("missing file workspace node");
    }
    fn row(self: *Fixture, side: files.Side, key: []const u8) *ui.Node {
        return rowWithPath(self.view.panes[@backingInt(side)].root, key) orelse @panic("missing file workspace row");
    }
};
fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |value| return value;
    return null;
}
fn rowWithPath(node: *ui.Node, key: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |id| if (std.mem.eql(u8, id, "files.row")) {
        if (node.behavior.interaction.a11y) |info| if (info.label) |value| if (std.mem.eql(u8, value, key)) return node;
    };
    for (node.children.items) |child| if (rowWithPath(child, key)) |value| return value;
    return null;
}
fn tooltipWithText(node: *ui.Node, value: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.component_name) |name| if (std.mem.eql(u8, name, "TooltipContent")) {
        for (node.children.items) |label| if (label.getText()) |style| if (std.mem.eql(u8, style.content, value)) return node;
    };
    for (node.children.items) |child| if (tooltipWithText(child, value)) |found| return found;
    return null;
}

test "file workspace file tooltip keeps filename path and metadata on separate visible lines" {
    var f: Fixture = undefined;
    try f.init(1194, 794);
    defer f.deinit();
    f.cx.setFocus(f.row(.local, entries[2].absolute_path));
    f.settle();
    const expected = "alpha.txt\n/tmp/fixture/alpha.txt\n1024 B · 10-20 09:12";
    const popup = tooltipWithText(f.cx.root.?, expected) orelse return error.TooltipNotVisible;
    const label = popup.children.items[0];
    const style = label.getText().?;
    const three_lines = style.font_size * style.line_height * 3;
    try std.testing.expect(label.globalRect().h >= three_lines - 0.5);
    try std.testing.expect(popup.globalRect().h >= label.globalRect().h + popup.style.padding.top + popup.style.padding.bottom - 0.5);
    try std.testing.expectEqualStrings(expected, style.content);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}

test "file workspace V3 independent cards and fixed header footer use measured geometry" {
    var f: Fixture = undefined;
    try f.init(1194, 794);
    defer f.deinit();
    for (f.view.panes) |pane| {
        try std.testing.expectEqual(@as(f32, 594), pane.root.globalRect().w);
        try std.testing.expectEqual(@as(f32, 794), pane.root.globalRect().h);
        try std.testing.expectEqual(@as(f32, 594), pane.table.globalRect().w);
        try std.testing.expectEqual(@as(f32, 623), pane.table.globalRect().h);
        try std.testing.expectEqual(@as(f32, 34), pane.header.globalRect().h);
        try std.testing.expectEqual(@as(f32, 758), pane.footer.globalRect().y);
        try std.testing.expectEqual(@as(f32, 758), pane.actions.globalRect().y);
        try std.testing.expectEqual(@as(f32, 312), pane.name_width);
    }
    try std.testing.expect(f.row(.local, entries[2].absolute_path).globalRect().h == 40);
    const aligned = f.row(.local, entries[2].absolute_path);
    const filename = find(aligned, "files.row.name").?.globalRect();
    // Browser computed styles, including the final V3 typography overrides.
    try std.testing.expectEqual(@as(f32, 12), find(aligned, "files.row.name").?.getText().?.font_size);
    try std.testing.expectEqual(@as(f32, 13), f.view.panes[0].title.getText().?.font_size);
    try std.testing.expectEqual(@as(u16, 700), f.view.panes[0].title.getText().?.font_weight);
    try std.testing.expectApproxEqAbs(aligned.globalRect().y + 20, filename.y + filename.h / 2, 0.5);
    try std.testing.expectEqual(f.view.panes[0].heading_buttons[0].globalRect().x + 22, find(aligned, "files.row.name").?.globalRect().x);
    try std.testing.expectEqual(f.view.panes[0].heading_buttons[1].globalRect().x, find(aligned, "files.row.size").?.globalRect().x);
    try std.testing.expectEqualStrings("0 B", find(f.row(.local, entries[3].absolute_path), "files.row.size").?.getText().?.content);
    try std.testing.expectEqualStrings("未知", find(f.row(.local, entries[4].absolute_path), "files.row.size").?.getText().?.content);
    try std.testing.expectEqualStrings("目录为空", f.view.panes[1].empty_text.getText().?.content);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}

test "file workspace narrow columns fit with independent vertical scrolling and fixed controls" {
    var f: Fixture = undefined;
    try f.init(790, 374);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const many = try arena.allocator().alloc(files.Entry, 80);
    for (many, 0..) |*entry, i| {
        const name = try std.fmt.allocPrint(arena.allocator(), "entry-{d:0>3}.txt", .{i});
        entry.* = .{ .absolute_path = try std.fmt.allocPrint(arena.allocator(), "/tmp/fixture/{s}", .{name}), .raw_name = name, .display_name = name, .kind = .file, .size = i, .modified_label = "2026-10-20 11:12", .modified_full = "2026-10-20T11:12:00+08:00" };
    }
    var next = f.current();
    next.revision += 1;
    next.panes[0].entries = many;
    try f.view.update(next);
    f.settle();
    const left = f.view.panes[0];
    const right = f.view.panes[1];
    try std.testing.expectEqual(@as(f32, 392), left.root.globalRect().w);
    try std.testing.expectEqual(@as(f32, 211), left.table.globalRect().h);
    try std.testing.expectEqual(@as(f32, 272), left.name_width);
    try std.testing.expectEqual(@as(f32, 392), left.column_width);
    try std.testing.expectEqual(@as(f32, 177), left.list.state.viewport_height);
    const footer = left.footer.globalRect();
    const path = left.path.node.globalRect();
    const header = left.header.globalRect();
    const body = left.list.container.globalRect();
    f.cx.handleScroll(.{ .x = body.x + 30, .y = body.y + 40, .dx = -10_000, .dy = -10_000 });
    f.settle();
    try std.testing.expect(left.list.state.scroll_x == 0 and left.list.state.scroll_y > 0);
    try std.testing.expectEqual(@as(f32, 0), left.list.state.scroll_x);
    try std.testing.expectEqual(left.list.content.style.translate_x, left.header.style.translate_x);
    try std.testing.expectEqual(@as(f32, 0), right.list.state.scroll_x);
    try std.testing.expectEqual(@as(f32, 0), right.list.state.scroll_y);
    try std.testing.expectEqual(footer, left.footer.globalRect());
    try std.testing.expectEqual(path, left.path.node.globalRect());
    try std.testing.expectEqual(header.y, left.header.globalRect().y);
    const date = left.heading_buttons[2].globalRect();
    try std.testing.expectEqual(@as(f32, 0), date.w);
    try std.testing.expect(left.heading_buttons[2].style.display == .none);
    f.cx.setViewport(1194, 794);
    f.settle();
    try std.testing.expectEqual(@as(f32, 0), left.list.state.scroll_x);
    try std.testing.expectEqual(@as(f32, 0), left.header.style.translate_x);
}

test "file workspace real row click Cmd Shift checkbox selection uses original keys and host ack" {
    var f: Fixture = undefined;
    try f.init(1194, 794);
    defer f.deinit();
    f.auto_ack = true;
    f.click(f.row(.local, entries[2].absolute_path), .{});
    try std.testing.expectEqual(@as(usize, 1), f.record.count);
    try std.testing.expectEqualStrings(entries[2].absolute_path, f.record.keys[0][0..f.record.lengths[0]]);
    try std.testing.expectEqual(@as(usize, 1), f.view.panes[0].projection().?.selected_keys.len);
    f.click(f.row(.local, entries[3].absolute_path), .{ .super = true });
    try std.testing.expectEqual(@as(usize, 2), f.record.count);
    try std.testing.expect(f.view.panes[0].mixed.peek());
    f.click(f.row(.local, entries[2].absolute_path), .{});
    f.click(f.row(.local, entries[4].absolute_path), .{ .shift = true });
    try std.testing.expectEqual(@as(usize, 3), f.record.count);
    try std.testing.expectEqual(@as(usize, 0), f.view.panes[1].projection().?.selected_keys.len);
    f.click(f.node(.local, "files.select_all"), .{});
    try std.testing.expectEqual(@as(usize, 4), f.record.count);
    for (0..f.record.count) |i| try std.testing.expect(!std.mem.eql(u8, entries[0].absolute_path, f.record.keys[i][0..f.record.lengths[i]]));
    try std.testing.expect(f.view.panes[0].all_checked.peek());
    const before = f.calls;
    f.click(f.node(.local, "files.transfer"), .{});
    try std.testing.expectEqual(before + 1, f.calls);
    try std.testing.expectEqual(std.meta.Tag(files.Action).transfer, f.record.tag);
    try std.testing.expectEqualStrings("/srv/fixture", f.record.path[0..f.record.path_len]);
    try std.testing.expectEqual(f.view.panes[1].projection().?.stamp, f.record.destination.?);
}

test "file workspace compact horizontal rail truly clips row paint and hit testing" {
    var f: Fixture = undefined;
    try f.init(620, 374);
    defer f.deinit();
    var many: [20]files.Entry = undefined;
    var paths: [20][64]u8 = undefined;
    for (&many, &paths, 0..) |*entry, *buffer, i| {
        const path = try std.fmt.bufPrint(buffer, "/tmp/fixture/rail-{d}.txt", .{i});
        entry.* = .{ .absolute_path = path, .raw_name = "rail.txt", .display_name = "rail.txt", .kind = .file, .size = 1 };
    }
    var next = f.current();
    next.revision += 1;
    next.panes[0].entries = &many;
    try f.view.update(next);
    f.settle();
    const pane = f.view.panes[0];
    const body = pane.list.container.globalRect();
    f.cx.handleScroll(.{ .x = body.x + 80, .y = body.y + 40, .dx = 0, .dy = -13 });
    f.settle();
    const clip = pane.list.content.parent.?;
    try std.testing.expect(clip != pane.list.container);
    try std.testing.expect(clip.style.overflow_hidden);
    try std.testing.expectEqual(@as(f32, 165), clip.globalRect().h);
    try std.testing.expectEqual(body.y + body.h - 12, clip.globalRect().y + clip.globalRect().h);
    const y = body.y + body.h - 6;
    f.cx.handleMouseDown(body.x + 80, y, .{});
    f.cx.handleMouseUp(body.x + 80, y);
    f.settle();
    try std.testing.expectEqual(@as(usize, 0), f.calls);
    // The real content clip ends before the reserved rail, independently of
    // the ScrollState viewport metric; data below it must not paint or hit.
}

test "file workspace directory double click survives selection acknowledgement and only navigates its pane" {
    var f: Fixture = undefined;
    try f.init(1194, 794);
    defer f.deinit();
    f.auto_ack = true;
    const row = f.row(.local, entries[1].absolute_path);
    f.click(row, .{});
    try std.testing.expectEqual(row, f.row(.local, entries[1].absolute_path));
    f.click(row, .{});
    try std.testing.expectEqual(std.meta.Tag(files.Action).navigate, f.record.tag);
    try std.testing.expectEqualStrings(entries[1].absolute_path, f.record.path[0..f.record.path_len]);
    try std.testing.expectEqual(f.view.panes[0].projection().?.stamp, f.record.stamp);
    try std.testing.expectEqualStrings("/srv/fixture", f.view.panes[1].path_value.peek());
}

test "file workspace keyboard focus advances through acknowledged original entries and copies selection" {
    var f: Fixture = undefined;
    try f.init(790, 374);
    defer f.deinit();
    f.auto_ack = true;
    f.click(f.row(.local, entries[2].absolute_path), .{});
    f.cx.setFocus(f.row(.local, entries[2].absolute_path));
    f.cx.handleKeyDown(.down, .{});
    f.settle();
    try std.testing.expectEqualStrings(entries[3].absolute_path, f.view.panes[0].projection().?.focused_key.?);
    try std.testing.expectEqual(f.row(.local, entries[3].absolute_path), f.cx.focused_node.?);
    f.cx.handleKeyDown(.down, .{});
    f.settle();
    try std.testing.expectEqualStrings(entries[4].absolute_path, f.view.panes[0].projection().?.focused_key.?);
    try std.testing.expectEqual(f.row(.local, entries[4].absolute_path), f.cx.focused_node.?);
    f.cx.handleKeyDown(.c, .{ .super = true });
    f.settle();
    try std.testing.expectEqual(std.meta.Tag(files.Action).copy_paths, f.record.tag);
    try std.testing.expectEqual(@as(usize, 1), f.record.count);
    try std.testing.expectEqualStrings(entries[2].absolute_path, f.record.keys[0][0..f.record.lengths[0]]);
    f.cx.handleKeyDown(.escape, .{});
    f.settle();
    try std.testing.expectEqual(f.row(.local, entries[4].absolute_path), f.cx.focused_node.?);
}

test "file workspace path Enter submits original input with frozen pane stamp" {
    var f: Fixture = undefined;
    try f.init(790, 374);
    defer f.deinit();
    const pane = f.view.panes[1];
    f.cx.setFocus(pane.path.input_container);
    f.cx.handleKeyDown(.a, .{ .super = true });
    f.cx.handleTextInput("../archive");
    f.settle();
    f.cx.handleKeyDown(.@"return", .{});
    f.settle();
    try std.testing.expectEqual(std.meta.Tag(files.Action).navigate, f.record.tag);
    try std.testing.expectEqualStrings("../archive", f.record.path[0..f.record.path_len]);
    try std.testing.expectEqual(pane.projection().?.stamp, f.record.stamp);
    try std.testing.expectEqual(@as(usize, 1), f.calls);
    try std.testing.expect(find(pane.root, "files.open_path") == null);
}

test "file workspace failed refresh preserves rows path and scroll and disables writes to stale destination" {
    var f: Fixture = undefined;
    try f.init(620, 374);
    defer f.deinit();
    var next = f.current();
    next.revision += 1;
    next.panes[1].entries = &entries;
    next.panes[1].state = .ready;
    next.panes[0].selected_keys = &.{entries[2].absolute_path};
    try f.view.update(next);
    f.settle();
    const remote = f.view.panes[1];
    const original = remote.projection().?;
    remote.list.state.scroll_x = 40;
    remote.list.content.setStyleInline(a, .{ .translate_x = -40 });
    f.settle();
    const retained_scroll_x = remote.list.state.scroll_x;
    next = f.current();
    next.revision += 1;
    next.panes[1].stamp.request_id += 1;
    next.panes[1].state = .failed;
    next.panes[1].failure = "Connection lost";
    next.panes[1].entries = &.{};
    next.panes[1].resolved_path = "/unreadable";
    try f.view.update(next);
    f.settle();
    try std.testing.expectEqual(original.entries.len, remote.projection().?.entries.len);
    try std.testing.expectEqualStrings("/srv/fixture", remote.path_value.peek());
    try std.testing.expectEqual(retained_scroll_x, remote.list.state.scroll_x);
    try std.testing.expect(remote.error_box.style.display == .flex);
    try std.testing.expectEqual(@as(f32, 68), remote.error_box.globalRect().h);
    // Hidden labels no longer add intrinsic gaps: the table receives those
    // eight pixels while visible siblings retain their exact gap and padding.
    const table = remote.table.globalRect();
    const stale = remote.stale_notice.globalRect();
    try std.testing.expect(remote.footer.style.display == .none);
    const failure = remote.error_box.globalRect();
    const pane = remote.root.globalRect();
    try std.testing.expectEqual(@as(f32, 163), table.h);
    try std.testing.expectEqual(stale.y + stale.h, table.y);
    try std.testing.expectEqual(table.y + table.h, failure.y);
    try std.testing.expectEqual(pane.y + pane.h, failure.y + failure.h);
    try std.testing.expect(f.node(.local, "files.transfer").behavior.interaction.a11y.?.disabled);
    try std.testing.expect(f.node(.remote, "files.new_folder").behavior.interaction.a11y.?.disabled);
    const calls = f.calls;
    f.click(f.node(.local, "files.transfer"), .{});
    f.click(f.node(.remote, "files.new_folder"), .{});
    try std.testing.expectEqual(calls, f.calls);
    f.click(f.node(.remote, "files.recover"), .{});
    try std.testing.expectEqual(std.meta.Tag(files.Action).recover, f.record.tag);
    try std.testing.expectEqual(original.stamp.endpoint, f.record.stamp.endpoint);
    try std.testing.expectEqualStrings("", remote.summary.getText().?.content);
    try std.testing.expectEqualStrings("上次列表 · 已过期", remote.error_detail.getText().?.content);
}

test "file workspace projection ownership old revisions and in-flight old press are rejected" {
    var f: Fixture = undefined;
    try f.init(1194, 794);
    defer f.deinit();
    var title = "Captured local title".*;
    var next = f.current();
    next.revision += 1;
    next.panes[0].title = &title;
    try f.view.update(next);
    @memset(&title, 'x');
    f.settle();
    try std.testing.expectEqualStrings("Captured local title", f.view.panes[0].projection().?.title);
    try std.testing.expectError(error.StaleFileProjection, f.view.update(f.current()));
    next = f.current();
    next.revision += 1;
    next.owner.generation += 1;
    for (&next.panes) |*p| p.stamp.owner = next.owner;
    try std.testing.expectError(error.FileOwnerChanged, f.view.update(next));
    const r = f.row(.local, entries[2].absolute_path).globalRect();
    f.cx.handleMouseDown(r.x + 80, r.y + 14, .{});
    next = f.current();
    next.revision += 1;
    next.panes[0].stamp.request_id += 1;
    next.panes[0].stamp.directory_revision += 1;
    try f.view.update(next);
    f.settle();
    f.cx.handleMouseUp(r.x + 80, r.y + 14);
    f.settle();
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}

test "file workspace global theme material updates every card without replacing projection or selection" {
    const theme = @import("ui/app_theme.zig");
    const saved = theme.currentName();
    const material = theme.materialVisible();
    defer {
        theme.select(saved);
        _ = theme.setMaterialVisible(material);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(false);
    var f: Fixture = undefined;
    try f.init(1194, 794);
    defer f.deinit();
    var next = f.current();
    next.revision += 1;
    next.panes[0].selected_keys = &.{entries[2].absolute_path};
    try f.view.update(next);
    f.settle();
    const revision = f.current().revision;
    theme.select(.light);
    _ = theme.setMaterialVisible(true);
    f.cx.setTheme(theme.widgetTheme(.light));
    f.view.retheme();
    f.settle();
    for (f.view.panes) |pane| {
        try std.testing.expectEqual(theme.current().terminal, pane.root.getBackground());
        try std.testing.expectEqual(theme.current().terminal, pane.table.getBackground());
        try std.testing.expectEqual(theme.current().fg_1, pane.title.getText().?.color);
        try std.testing.expectEqual(@as(f32, 11.5), pane.path.state.text_display_node.?.getText().?.font_size);
    }
    try std.testing.expectEqual(theme.current().selection, f.row(.local, entries[2].absolute_path).getBackground());
    try std.testing.expectEqual(revision, f.current().revision);
    try std.testing.expectEqualStrings(entries[2].absolute_path, f.view.panes[0].projection().?.selected_keys[0]);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}

fn dragStart(f: *Fixture, key: []const u8) void {
    const handle = find(f.row(.local, key), "files.row.drag").?;
    const r = handle.globalRect();
    const x = r.x + @min(@as(f32, 100), r.w / 2);
    const y = r.y + r.h / 2;
    f.cx.handleMouseDown(x, y, .{});
    f.settle();
    f.cx.handleMouseMove(x + 8, y);
    f.settle();
}

test "file workspace actual Cx cross-card drag freezes source and opens one confirmation action only on release" {
    var f: Fixture = undefined;
    try f.init(1194, 794);
    defer f.deinit();
    f.auto_ack = true;
    dragStart(&f, entries[2].absolute_path);
    try std.testing.expect(f.view.drag_source != null);
    const target = f.view.panes[1].data_clip.globalRect();
    f.cx.handleMouseMove(target.x + 100, target.y + 80);
    f.settle();
    try std.testing.expectEqual(files.Side.remote, f.view.drop_side.?);
    try std.testing.expectEqualStrings("/srv/fixture", f.view.panes[1].drag_target.getText().?.content);
    try std.testing.expect(f.view.panes[1].drag_preview.style.display == .flex);
    try std.testing.expect(f.record.tag != .transfer);
    f.cx.handleMouseUp(target.x + 100, target.y + 80);
    f.settle();
    try std.testing.expectEqual(std.meta.Tag(files.Action).transfer, f.record.tag);
    try std.testing.expectEqual(@as(usize, 1), f.record.count);
    try std.testing.expectEqualStrings(entries[2].absolute_path, f.record.keys[0][0..f.record.lengths[0]]);
    try std.testing.expectEqualStrings("/srv/fixture", f.record.path[0..f.record.path_len]);
    try std.testing.expect(f.record.stamp.owner.eql(owner));
    try std.testing.expectEqual(@as(u64, 7), f.record.destination.?.endpoint.binding_id);
    try std.testing.expect(f.view.drag_source == null and f.view.drop_side == null);
    try std.testing.expect(f.view.panes[1].drag_preview.style.display == .none);
}

test "file workspace drag folder target is exact metadata and file target or Escape never transfers" {
    const remote_entries = [_]files.Entry{
        .{ .absolute_path = "/srv/fixture/shared", .raw_name = "shared", .display_name = "shared", .kind = .directory },
        .{ .absolute_path = "/srv/fixture/folder.zip", .raw_name = "folder.zip", .display_name = "folder.zip", .kind = .file },
    };
    var f: Fixture = undefined;
    try f.init(1194, 794);
    defer f.deinit();
    f.auto_ack = true;
    var projection = f.current();
    projection.revision += 1;
    projection.panes[1].entries = &remote_entries;
    projection.panes[1].state = .ready;
    try f.view.update(projection);
    f.settle();
    dragStart(&f, entries[2].absolute_path);
    const folder = f.row(.remote, remote_entries[0].absolute_path).globalRect();
    f.cx.handleMouseMove(folder.x + 100, folder.y + folder.h / 2);
    f.settle();
    try std.testing.expectEqualStrings(remote_entries[0].absolute_path, f.view.panes[1].drag_target.getText().?.content);
    f.cx.handleMouseUp(folder.x + 100, folder.y + folder.h / 2);
    f.settle();
    try std.testing.expectEqual(std.meta.Tag(files.Action).transfer, f.record.tag);
    try std.testing.expectEqualStrings(remote_entries[0].absolute_path, f.record.path[0..f.record.path_len]);
    const calls = f.calls;
    dragStart(&f, entries[2].absolute_path);
    const file = f.row(.remote, remote_entries[1].absolute_path).globalRect();
    f.cx.handleMouseMove(file.x + 100, file.y + file.h / 2);
    f.settle();
    try std.testing.expect(f.view.drop_side == null);
    f.cx.handleMouseUp(file.x + 100, file.y + file.h / 2);
    f.settle();
    try std.testing.expectEqual(calls, f.calls);
    dragStart(&f, entries[2].absolute_path);
    f.cx.handleMouseMove(folder.x + 100, folder.y + folder.h / 2);
    f.settle();
    f.cx.handleKeyDown(.escape, .{});
    f.settle();
    f.cx.handleMouseUp(folder.x + 100, folder.y + folder.h / 2);
    f.settle();
    try std.testing.expectEqual(calls, f.calls);
    try std.testing.expect(f.view.drag_source == null and f.view.drop_side == null);
}
