//! Real Cx projection of the original VT owner and immutable text snapshot.
const std = @import("std");
const ui = @import("ui");
const A = @import("ai/local_text_attachments.zig");
const T = @import("ai/terminal_text_attachments.zig");
const V = @import("ui/ai_attachments_view.zig");
const a = std.testing.allocator;
const original: A.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 7 };
const captured_bytes = "14:20:05 原始日志\n14:20:06 second line";

const Scene = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *V.View,
    draft: A.Draft,
    attached: usize = 0,
    removed: usize = 0,
    fn init(self: *Scene) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .view = undefined, .draft = try A.Draft.init(a, .{ .session = 101 }) };
        self.cx.setViewport(1200, 900);
        try self.cx.setTestFrameStep(16);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        const holder = try ui.box(self.cx, .{ .position = .absolute, .width = .{ .px = 572 }, .inset = .{ .left = .{ .px = 100 }, .top = .{ .px = 100 } } }, .{});
        try self.cx.root.?.appendChild(a, holder);
        self.view = try V.View.mountInline(self.cx, self.scope, .{ .context = self, .attach = attach, .remove = remove, .reselect = reselect }, holder);
        self.view.root.setStyleInline(a, .{ .position = .absolute, .width = .{ .px = 600 }, .inset = .{ .left = .{ .px = 100 }, .top = .{ .px = 500 } } });
        try self.cx.root.?.appendChild(a, self.view.root);
        self.settle();
    }
    fn deinit(self: *Scene) void {
        self.scope.dispose();
        self.cx.deinit();
        self.draft.deinit();
    }
    fn stage(self: *Scene) !A.Ticket {
        const ticket = try self.draft.beginTerminal(original);
        var ref = try T.createSelection(a, .{ .owner = original, .source_name = "原会话", .source_version = 42, .selected_rows = 2, .selection = .{ .start = .{ .owner = original, .id = 1 }, .end = .{ .owner = original, .id = 2 } } }, captured_bytes, 1_792_561_208_000);
        try self.draft.stage(ticket, &ref);
        try self.view.update(&self.draft);
        self.settle();
        return ticket;
    }
    fn attach(raw: *anyopaque, ticket: A.Ticket) !void {
        const self: *Scene = @ptrCast(@alignCast(raw));
        _ = try self.draft.attach(ticket);
        self.attached += 1;
        try self.view.update(&self.draft);
    }
    fn remove(raw: *anyopaque, ticket: A.Ticket) !void {
        const self: *Scene = @ptrCast(@alignCast(raw));
        if (!self.draft.owner.eql(ticket.owner) or self.draft.epoch != ticket.draft_epoch) return error.StaleAttachment;
        if (!self.draft.remove(ticket.id)) return error.StaleAttachment;
        self.removed += 1;
        try self.view.update(&self.draft);
    }
    fn reselect(_: *anyopaque, _: A.Ticket) !void {
        return error.TerminalSnapshotMustNotOpenFilePicker;
    }
    fn settle(self: *Scene) void {
        for (0..16) |_| {
            self.cx.advanceFrameClock();
            _ = self.cx.render();
        }
    }
    fn click(self: *Scene, node: *ui.Node) void {
        const r = node.globalRect();
        self.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
        self.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
        self.settle();
    }
};
fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |value| return value;
    return null;
}

test "AI VT candidate preserves original full ticket and R11 metadata until explicit attach" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();
    const ticket = try s.stage();
    try std.testing.expect(ticket.eql(s.view.preview_ticket.?));
    try std.testing.expectEqualStrings("文件预览", s.view.preview_title.getText().?.content);
    try std.testing.expectEqualStrings("终端选区.txt", s.view.preview_identity.getText().?.content);
    var buffer: [160]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "原会话 #101 · 2 行 · {d} B", .{captured_bytes.len}), s.view.preview_metadata.getText().?.content);
    try std.testing.expectEqualStrings(captured_bytes, s.view.preview_label.getText().?.content);
    try std.testing.expectApproxEqAbs(@as(f32, 936), s.view.preview_panel.globalRect().w, 0.1);
    try std.testing.expect(s.view.preview_panel.globalRect().h < s.cx.viewport.height - 32);
    const panel = s.view.preview_panel.globalRect();
    const body = s.view.preview_body.container.globalRect();
    try std.testing.expect(body.h > panel.h / 2);
    try std.testing.expect(body.y >= panel.y and body.y + body.h <= panel.y + panel.h);
    try std.testing.expectEqual(ui.types.Display.none, s.view.preview_reselect.style.display);
    try std.testing.expectEqual(@as(usize, 0), s.draft.items.items.len);
    try std.testing.expectError(error.AttachmentsProcessing, s.draft.freeze());
    s.click(s.view.preview_primary);
    try std.testing.expectEqual(@as(usize, 1), s.attached);
    try std.testing.expectEqual(@as(usize, 1), s.draft.items.items.len);
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "#101 · {d} B · 2 行", .{captured_bytes.len}), find(s.view.root, "ai.attachment.metadata").?.getText().?.content);
    try std.testing.expect(!s.view.isPreviewOpen());
    s.click(find(s.view.root, "ai.attachment.open").?);
    try std.testing.expectEqualStrings(captured_bytes, s.view.preview_label.getText().?.content);
    s.click(s.view.preview_remove);
    try std.testing.expectEqual(@as(usize, 1), s.removed);
    try std.testing.expectEqual(@as(usize, 0), s.draft.items.items.len);
}

test "AI VT history primary closes original snapshot and never attaches or removes from a new owner" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();
    const ticket = try s.stage();
    _ = try s.draft.attach(ticket);
    var sent = try s.draft.freeze();
    defer sent.deinit();
    try s.view.updateSent(&sent);
    _ = s.draft.remove(ticket.id);
    s.settle();
    s.click(find(s.view.root, "ai.attachment.open").?);
    try std.testing.expectEqualStrings("关闭预览", s.view.preview_primary.behavior.interaction.a11y.?.label.?);
    try std.testing.expectEqual(ui.types.Display.none, s.view.preview_remove.style.display);
    try std.testing.expectEqual(ui.types.Display.none, s.view.preview_reselect.style.display);
    try std.testing.expectEqualStrings(captured_bytes, s.view.preview_label.getText().?.content);
    s.click(s.view.preview_primary);
    try std.testing.expect(!s.view.isPreviewOpen());
    try std.testing.expectEqual(@as(usize, 0), s.attached);
    try std.testing.expectEqual(@as(usize, 0), s.removed);
    try std.testing.expectEqualStrings(captured_bytes, sent.items[0].reference.content().?.bytes);
}
