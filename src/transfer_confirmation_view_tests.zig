const std = @import("std");

test "transfer confirmation first chooser accepts result drop keeps directory and anchor is frozen" {
    var c: Capture = .{};
    const h = try H.init(&c, 1000, 800);
    defer h.deinit();
    const pane = try ui.box(h.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 200 }, .top = .{ .px = 60 } }, .width = .{ .px = 780 }, .height = .{ .px = 700 } }, .{});
    try h.root.appendChild(h.cx.allocator, pane);
    h.panel.setPaneAnchor(pane);
    h.panel.show(.{ .mode = .upload, .presentation = .drop, .owner = testOwner(), .remote_dir = "/srv" });
    h.frames();
    const r = h.panel.card.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 590), r.x + r.w / 2, 1);
    try h.panel.replaceSource(0, h.panel.source_revision, "/tmp/new file");
    h.frames();
    h.panel.handleSubmit();
    try std.testing.expectEqual(@as(usize, 1), c.calls);
    const other = try ui.box(h.cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try h.root.appendChild(h.cx.allocator, other);
    h.panel.setPaneAnchor(other);
    try std.testing.expectEqual(@as(?u32, pane.id), h.panel.pane_anchor_id);
}
const ui = @import("ui");
const P = @import("ui/transfer_panel.zig");
const theme = @import("ui/app_theme.zig");
const identity = @import("host/identity.zig");
const transfer = @import("transfer/manager.zig");
const Capture = struct {
    calls: usize = 0,
    notify_complete: ?bool = null,
    owner: ?identity.SessionHandle = null,
    session: u64 = 0,
    first: [256]u8 = undefined,
    source_len: usize = 0,
    source_count: usize = 0,
    local: [256]u8 = undefined,
    local_len: usize = 0,
    directory_calls: usize = 0,
    rename: [256]u8 = undefined,
    rename_len: usize = 0,
    fail: bool = false,
    replace_index: ?usize = null,
    replace_revision: u64 = 0,
    fn submit(raw: *anyopaque, owner: identity.SessionHandle, spec: transfer.JobSpec) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.fail) return error.PermissionDenied;
        self.calls += 1;
        self.owner = owner;
        self.session = spec.session_id;
        self.notify_complete = spec.notify_complete;
        self.source_count = spec.sources.len;
        self.local_len = spec.local_dir.len;
        @memcpy(self.local[0..self.local_len], spec.local_dir);
        self.source_len = spec.sources[0].len;
        @memcpy(self.first[0..self.source_len], spec.sources[0]);
        if (spec.rename) |rename| {
            self.rename_len = rename.len;
            @memcpy(self.rename[0..rename.len], rename);
        }
    }
    fn directory(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.directory_calls += 1;
    }
    fn replace(raw: *anyopaque, index: usize, revision: u64) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.replace_index = index;
        self.replace_revision = revision;
    }
};
const H = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    root: *ui.Node,
    panel: *P.Panel,
    fn init(c: *Capture, width: f32, height: f32) !H {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(width, height);
        cx.setTheme(theme.widgetTheme(theme.currentName()));
        const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        cx.root = root;
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        const panel = try std.testing.allocator.create(P.Panel);
        panel.* = .{};
        // Native mountUI holds an outer mount transaction. Modal YSS effects
        // settle only when it ends, after the component's mount returned.
        cx.owner.enterMount();
        const anchor = panel.mount(cx, scope) catch |err| {
            cx.owner.exitMount();
            return err;
        };
        cx.owner.exitMount();
        try root.appendChild(cx.allocator, anchor);
        panel.submit_ctx = c;
        panel.on_submit_frozen = Capture.submit;
        panel.on_replace_source = Capture.replace;
        return .{ .cx = cx, .scope = scope, .root = root, .panel = panel };
    }
    fn deinit(self: H) void {
        self.scope.dispose();
        std.testing.allocator.destroy(self.panel);
        self.cx.deinit();
    }
    fn frames(self: H) void {
        for (0..5) |_| {
            self.cx.frame_count += 1;
            self.cx.frame_time_ms += 16;
            _ = self.cx.render();
        }
    }
    fn click(self: H, node: *ui.Node) void {
        const r = node.globalRect();
        self.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
        self.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
    }
};
fn find(node: *ui.Node, value: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |actual| if (std.mem.eql(u8, actual, value)) return node;
    for (node.children.items) |child| if (find(child, value)) |found| return found;
    return null;
}
fn hasText(node: *ui.Node, value: []const u8) bool {
    if (node.getText()) |actual| if (std.mem.eql(u8, actual.content, value)) return true;
    for (node.children.items) |child| if (hasText(child, value)) return true;
    return false;
}
fn testOwner() identity.SessionHandle {
    return .{ .session_id = @fromBackingInt(101), .generation = 7 };
}
test "transfer confirmation actual Modal exact three cards and source fields" {
    const original = theme.currentName();
    defer theme.select(original);
    theme.select(.dark);
    var c: Capture = .{};
    const h = try H.init(&c, 1000, 800);
    defer h.deinit();
    for ([_]struct { mode: P.Data.Mode, drop: bool, height: f32 }{ .{ .mode = .upload, .drop = false, .height = 367.5 }, .{ .mode = .download, .drop = false, .height = 383.5 }, .{ .mode = .upload, .drop = true, .height = 341.5 } }) |variant| {
        h.panel.show(.{ .mode = variant.mode, .presentation = if (variant.drop) P.Data.Presentation.drop else P.Data.Presentation.command, .owner = testOwner(), .host_name = "生产机", .endpoint = "root@192.0.2.10:22", .link_text = "经真实跳板", .sources = &.{"/tmp/a b,c.tar"}, .remote_dir = "/srv", .local_dir = "/tmp", .rename = if (variant.mode == .download) "release.tar" else "" });
        // Reproduce the native diagnostic: the shared Modal body resolves to
        // its default 16px inset after the panel's first mount-time styling.
        h.panel.body.setStyleInline(h.cx.allocator, .{ .padding = ui.Padding.all(16) });
        h.frames();
        try std.testing.expectEqual(ui.Padding.ZERO, h.panel.body.style.padding);
        const r = h.panel.card.globalRect();
        try std.testing.expectApproxEqAbs(@as(f32, 520), r.w, 0.1);
        try std.testing.expectApproxEqAbs(variant.height, r.h, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 48), h.panel.header.globalRect().h, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 81.5), h.panel.identity_box.globalRect().h, 0.1);
        try std.testing.expectApproxEqAbs(h.panel.viewport.?.content.globalRect().h, h.panel.viewport.?.container.globalRect().h, 0.1);
        const options = h.panel.viewport.?.content.children.items[h.panel.viewport.?.content.children.items.len - 1];
        const options_rect = options.globalRect();
        const visible_body = h.panel.viewport.?.container.globalRect();
        try std.testing.expect(options_rect.y >= visible_body.y and options_rect.y + options_rect.h <= visible_body.y + visible_body.h + 0.1);
        var ancestor = options.parent;
        while (ancestor) |node| : (ancestor = node.parent) {
            if (!node.style.overflow_hidden) continue;
            const clip = node.globalRect();
            try std.testing.expect(options_rect.y >= clip.y - 0.1 and options_rect.y + options_rect.h <= clip.y + clip.h + 0.1);
        }
        const previous_md5 = h.panel.md5;
        h.click(options.children.items[1]);
        try std.testing.expectEqual(!previous_md5, h.panel.md5);
        h.panel.viewport.?.content.setStyleInline(h.cx.allocator, .{ .height = .{ .px = visible_body.h - 34 } });
        h.frames();
        try std.testing.expectApproxEqAbs(variant.height, h.panel.card.globalRect().h, 0.1);
        const repaired_options = options.globalRect();
        const repaired_viewport = h.panel.viewport.?.container.globalRect();
        try std.testing.expect(repaired_options.y + repaired_options.h <= repaired_viewport.y + repaired_viewport.h + 0.1);
        h.click(options.children.items[1]);
        try std.testing.expectEqual(previous_md5, h.panel.md5);
        h.panel.viewport.?.content.setStyleInline(h.cx.allocator, .{ .height = .{ .fit = .{} } });
        try std.testing.expectApproxEqAbs(r.y + r.h - 16, h.panel.footer.globalRect().y + h.panel.footer.globalRect().h, 0.1);
        for ([_][]const u8{ "使用此会话的连接传输", "切换页签后仍使用此目标", "提交前确认", "同名文件会逐项询问；传输归属于上方目标会话。" }) |removed| try std.testing.expect(!hasText(h.panel.card, removed));
        try std.testing.expectApproxEqAbs(@as(f32, 32), h.panel.source_rows.children.items[0].globalRect().h, 0.1);
        try std.testing.expect(!h.panel.disabled.peek());
        h.panel.hide();
        h.frames();
    }
}
test "transfer confirmation real replace remove preserve other sources and reject stale dialog" {
    var c: Capture = .{};
    const h = try H.init(&c, 1000, 800);
    defer h.deinit();
    h.panel.show(.{ .mode = .upload, .owner = testOwner(), .sources = &.{ "/tmp/a b,c.tar", "/tmp/other" }, .remote_dir = "/srv" });
    h.frames();
    h.click(find(h.panel.source_rows, "transfer.source.replace").?);
    try std.testing.expectEqual(@as(usize, 0), c.replace_index.?);
    try h.panel.replaceSource(0, c.replace_revision, "/tmp/replaced");
    h.frames();
    try std.testing.expectEqualStrings("/tmp/replaced\n/tmp/other", h.panel.sources_sig.peek());
    try std.testing.expectError(error.StaleSelection, h.panel.replaceSource(0, c.replace_revision, "/tmp/stale"));
    h.click(find(h.panel.source_rows, "transfer.source.remove").?);
    h.frames();
    try std.testing.expectEqualStrings("/tmp/other", h.panel.sources_sig.peek());
    h.click(find(h.panel.root, "transfer.confirmation.submit").?);
    try std.testing.expectEqual(testOwner(), c.owner.?);
    try std.testing.expectEqual(@as(u64, 101), c.session);
    try std.testing.expectEqual(@as(usize, 1), c.source_count);
    try std.testing.expectEqualStrings("/tmp/other", c.first[0..c.source_len]);
}
test "transfer confirmation download invalid name unknown owner service failure keep draft" {
    var c: Capture = .{};
    const h = try H.init(&c, 1000, 800);
    defer h.deinit();
    h.panel.show(.{ .mode = .download, .owner = testOwner(), .sources = &.{"/srv/file"}, .local_dir = "/tmp", .rename = "../bad" });
    h.frames();
    try std.testing.expect(h.panel.disabled.peek());
    h.panel.handleSubmit();
    try std.testing.expectEqual(@as(usize, 0), c.calls);
    h.panel.rename_sig.set("fixed.tar");
    h.frames();
    try std.testing.expect(!h.panel.disabled.peek());
    c.fail = true;
    h.click(find(h.panel.root, "transfer.confirmation.submit").?);
    h.frames();
    try std.testing.expect(h.panel.isVisible());
    try std.testing.expectEqualStrings("fixed.tar", h.panel.rename_sig.peek());
    try std.testing.expect(h.panel.status_row.style.display != .none);
    c.fail = false;
    h.click(find(h.panel.root, "transfer.confirmation.submit").?);
    try std.testing.expectEqual(@as(usize, 1), c.calls);
    h.panel.show(.{ .mode = .download, .sources = &.{"/srv/file"}, .local_dir = "/tmp" });
    h.frames();
    try std.testing.expect(h.panel.disabled.peek());
    h.panel.handleSubmit();
    try std.testing.expectEqual(@as(usize, 1), c.calls);
    h.panel.show(.{ .mode = .download, .owner = testOwner(), .sources = &.{"/srv/file"}, .local_dir = "/tmp", .available = false, .unavailable_reason = "原连接不可用" });
    h.frames();
    try std.testing.expect(h.panel.disabled.peek());
    h.panel.handleSubmit();
    try std.testing.expectEqual(@as(usize, 1), c.calls);
}
test "transfer confirmation palettes material short viewport and stale overlong paths" {
    const saved = theme.currentName();
    const material = theme.materialVisible();
    defer {
        theme.select(saved);
        _ = theme.setMaterialVisible(material);
    }
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        _ = theme.setMaterialVisible(true);
        var c: Capture = .{};
        const h = try H.init(&c, 420, 260);
        defer h.deinit();
        h.panel.show(.{ .mode = .download, .owner = testOwner(), .sources = &.{"/srv/file"}, .local_dir = "/tmp", .rename = "hello" });
        h.frames();
        const card = h.panel.card.globalRect();
        const submit = h.panel.primary.globalRect();
        try std.testing.expect(card.w <= 396.1 and card.h <= 236.1);
        try std.testing.expect(submit.y >= card.y and submit.y + submit.h <= card.y + card.h);
        try std.testing.expectEqual(theme.current().overlay, h.panel.card.getBackground());
        const long = try std.testing.allocator.alloc(u8, 5000);
        defer std.testing.allocator.free(long);
        @memset(long, 'x');
        h.panel.local_dir_sig.set(long);
        h.frames();
        try std.testing.expect(h.panel.disabled.peek());
        h.panel.handleSubmit();
        try std.testing.expectEqual(@as(usize, 0), c.calls);
    }
}

test "transfer confirmation SSH remote Input requires a picker receipt for the same source" {
    var c: Capture = .{};
    const h = try H.init(&c, 1000, 800);
    defer h.deinit();
    h.panel.on_local_directory = Capture.directory;
    h.panel.show(.{ .mode = .download, .owner = testOwner(), .host_name = "原 SSH", .edit_remote_source = true, .require_directory_selection = true, .local_dir = "/suggested/default" });
    h.frames();
    try std.testing.expectApproxEqAbs(@as(f32, 520), h.panel.card.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 344), h.panel.card.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 42), h.panel.identity_box.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 32), h.panel.download_source_row.globalRect().h, 0.1);
    try std.testing.expect(h.panel.source_rows.style.display == .none);
    const source = find(h.panel.root, "transfer.remote_source").?;
    h.cx.setFocus(source);
    h.cx.handleTextInput("/fixture/release.txt");
    h.frames();
    try std.testing.expectEqualStrings("/fixture/release.txt", h.panel.sources_sig.peek());
    try std.testing.expect(h.panel.disabled.peek());
    try std.testing.expectEqualStrings("/suggested/default", h.panel.local_dir_sig.peek());
    try std.testing.expectEqualStrings("", h.panel.directory_selection.peek());
    try std.testing.expect(h.panel.local_input.state.readonly);
    try std.testing.expect(h.panel.local_input.input_container.behavior.interaction.text_input_client == null);
    h.cx.setFocus(h.panel.local_input.input_container);
    h.cx.handleTextInput("/typed/bypass");
    h.frames();
    try std.testing.expectEqualStrings("/suggested/default", h.panel.local_dir_sig.peek());
    // A prefilled value is not a system-selection receipt.
    h.panel.local_dir_sig.set("/prefilled/bypass");
    h.frames();
    h.panel.handleSubmit();
    try std.testing.expect(h.panel.disabled.peek());
    try std.testing.expectEqual(@as(usize, 0), c.calls);
    h.click(find(h.panel.root, "transfer.directory.choose").?);
    try std.testing.expectEqual(@as(usize, 1), c.directory_calls);
    try std.testing.expectEqual(@as(usize, 0), c.calls);
    const ticket = try h.panel.directoryTicket();
    try std.testing.expectEqual(testOwner(), ticket.owner);
    try h.panel.applyDirectorySelection(ticket, "/private/selected");
    h.frames();
    try std.testing.expect(!h.panel.disabled.peek());
    h.click(h.panel.primary);
    try std.testing.expectEqual(@as(usize, 1), c.calls);
    try std.testing.expectEqual(testOwner(), c.owner.?);
    try std.testing.expectEqualStrings("/fixture/release.txt", c.first[0..c.source_len]);
    try std.testing.expectEqualStrings("/private/selected", c.local[0..c.local_len]);
    // Editing the remote source revokes permission, while the previous path
    // remains only a starting location for a new system-picker selection.
    h.cx.setFocus(source);
    h.cx.handleKeyDown(.a, .{ .super = true });
    h.cx.handleTextInput("/fixture/other.txt");
    h.frames();
    try std.testing.expectEqualStrings("/fixture/other.txt", h.panel.sources_sig.peek());
    try std.testing.expectEqualStrings("/private/selected", h.panel.local_dir_sig.peek());
    try std.testing.expectEqualStrings("", h.panel.directory_selection.peek());
    try std.testing.expect(h.panel.disabled.peek());
    try std.testing.expectError(error.StaleSelection, h.panel.applyDirectorySelection(ticket, "/stale/picker"));
}

test "transfer confirmation picker tickets reject replaced forms and preserve file-card selection" {
    var c: Capture = .{};
    const h = try H.init(&c, 1000, 800);
    defer h.deinit();
    const draft: P.Data = .{ .mode = .download, .owner = testOwner(), .sources = &.{"/fixture/release.txt"}, .edit_remote_source = true, .require_directory_selection = true };
    h.panel.show(draft);
    h.frames();
    const old = try h.panel.directoryTicket();
    h.panel.hide();
    try std.testing.expectError(error.StaleSelection, h.panel.applyDirectorySelection(old, "/private/selected"));
    h.panel.show(draft);
    h.frames();
    try std.testing.expectError(error.StaleSelection, h.panel.applyDirectorySelection(old, "/private/selected"));
    const current = try h.panel.directoryTicket();
    var wrong_owner = current;
    wrong_owner.owner.generation += 1;
    try std.testing.expectError(error.StaleOwner, h.panel.applyDirectorySelection(wrong_owner, "/private/selected"));
    try std.testing.expectError(error.InvalidLocalDirectory, h.panel.applyDirectorySelection(current, "relative"));
    try std.testing.expect(h.panel.disabled.peek());
    // Existing SFTP file cards retain multiple frozen sources and chosen directory.
    h.panel.show(.{ .mode = .download, .owner = testOwner(), .sources = &.{ "/fixture/a", "/fixture/b" }, .local_dir = "/filecard/original" });
    h.frames();
    try std.testing.expect(h.panel.download_source_row.style.display == .none);
    try std.testing.expect(h.panel.source_rows.style.display != .none);
    try std.testing.expect(!h.panel.local_input.state.readonly);
    try std.testing.expect(h.panel.local_input.input_container.behavior.interaction.text_input_client != null);
    try std.testing.expect(!h.panel.disabled.peek());
    const filecard = try h.panel.directoryTicket();
    try h.panel.applyDirectorySelection(filecard, "/filecard/reselected");
    h.frames();
    h.click(h.panel.primary);
    try std.testing.expectEqual(@as(usize, 1), c.calls);
    try std.testing.expectEqual(@as(usize, 2), c.source_count);
    try std.testing.expectEqualStrings("/filecard/reselected", c.local[0..c.local_len]);
}

test "transfer notification choice submits the actual off chip and survives reopening and retheme" {
    var c: Capture = .{};
    const h = try H.init(&c, 1000, 800);
    defer h.deinit();
    h.panel.show(.{ .mode = .download, .owner = testOwner(), .sources = &.{"/srv/a"}, .local_dir = "/tmp" });
    h.frames();
    h.click(find(h.panel.root, "transfer.confirmation.notify").?);
    h.frames();
    try std.testing.expect(!h.panel.notify_complete);
    h.panel.retheme();
    h.frames();
    h.click(find(h.panel.root, "transfer.confirmation.submit").?);
    try std.testing.expectEqual(@as(usize, 1), c.calls);
    try std.testing.expectEqual(@as(?bool, false), c.notify_complete);
    h.panel.show(.{ .mode = .upload, .owner = testOwner(), .sources = &.{"/tmp/a"}, .remote_dir = "/srv", .notify_complete = false });
    h.frames();
    h.click(find(h.panel.root, "transfer.confirmation.submit").?);
    try std.testing.expectEqual(@as(usize, 2), c.calls);
    try std.testing.expectEqual(@as(?bool, false), c.notify_complete);
}
