const std = @import("std");
const ui = @import("ui");
const images = @import("ai/image_attachments.zig");
const V = @import("ui/ai_image_attachments_view.zig");
const a = std.testing.allocator;

test "AI images show processing and error retry in the original four fixed slots" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 600);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    var draft = try images.Draft.init(a, .{ .session = 101 });
    defer draft.deinit();
    const holder = try ui.box(cx, .{ .width = .{ .px = 572 } }, .{});
    try cx.root.?.appendChild(a, holder);
    const view = try V.View.mount(cx, scope, .{ .context = &draft }, holder);
    try cx.root.?.appendChild(a, view.root);
    const ticket = try draft.begin("/explicit/selected.png", .{});
    try view.update(&draft);
    for (0..4) |_| _ = cx.render();
    try std.testing.expectEqual(@as(usize, 1), view.count);
    try std.testing.expectEqualStrings("图片处理中", view.cards[0].metadata.getText().?.content);
    try std.testing.expectEqual(ui.types.Display.none, view.cards[0].retry_button.style.display);
    try std.testing.expectEqual(@as(f32, 184), view.cards[0].root.globalRect().w);
    try std.testing.expectEqual(@as(f32, 44), view.cards[0].root.globalRect().h);
    try std.testing.expect(draft.fail(ticket, error.AccessDenied));
    try view.update(&draft);
    try std.testing.expectEqual(ui.types.Display.flex, view.cards[0].retry_button.style.display);
    _ = try draft.retry(ticket);
    try view.update(&draft);
    try std.testing.expectEqual(ui.types.Display.none, view.cards[0].retry_button.style.display);
    try draft.clear();
    try view.update(&draft);
    try std.testing.expectEqual(ui.types.Display.none, view.root.style.display);
}

const pixel_png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
    "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++
    "\x00\x00\x00\x00IEND\xae\x42\x60\x82";

const PreviewFixture = struct {
    draft: images.Draft,
    view: *V.View = undefined,
    removed: ?images.Ticket = null,
    fn remove(raw: *anyopaque, ticket: images.Ticket) !void {
        const self: *PreviewFixture = @ptrCast(@alignCast(raw));
        if (self.draft.find(ticket) == null) return error.StaleAttachment;
        self.removed = ticket;
        _ = self.draft.remove(ticket.id);
        try self.view.update(&self.draft);
    }
};
fn settle(cx: *ui.Cx) void {
    for (0..8) |_| {
        cx.layout();
        _ = cx.render();
    }
}
fn click(cx: *ui.Cx, node: *ui.Node) void {
    settle(cx);
    const rect = node.globalRect();
    cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
    cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
    settle(cx);
}

test "AI images inline retain escape remove and immutable history use one captured raster" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 700);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    var fixture: PreviewFixture = .{ .draft = try images.Draft.init(a, .{ .session = 101 }) };
    defer fixture.draft.deinit();
    const holder = try ui.box(cx, .{ .width = .{ .px = 572 } }, .{});
    try cx.root.?.appendChild(a, holder);
    fixture.view = try V.View.mount(cx, scope, .{ .context = &fixture, .remove = PreviewFixture.remove }, holder);
    try cx.root.?.appendChild(a, fixture.view.root);
    const ticket = try fixture.draft.begin("/original/captured.png", .{});
    var reference = try images.ContentRef.create(a, "/original/captured.png", pixel_png, 123, .{});
    try fixture.draft.complete(ticket, &reference);
    try fixture.view.update(&fixture.draft);
    settle(cx);
    click(cx, fixture.view.cards[0].preview);
    try std.testing.expect(fixture.view.isPreviewOpen());
    try std.testing.expectEqual(@as(f32, 194), fixture.view.panel.globalRect().h);
    try std.testing.expectEqual(@as(f32, 104), fixture.view.preview_image.globalRect().h);
    try std.testing.expectEqualStrings("/original/captured.png", fixture.view.identity.getText().?.content);
    click(cx, fixture.view.keep_button);
    try std.testing.expect(!fixture.view.isPreviewOpen());
    try std.testing.expectEqual(@as(usize, 1), fixture.draft.items.items.len);
    click(cx, fixture.view.cards[0].preview);
    try std.testing.expect(fixture.view.escapePreview());
    try std.testing.expectEqual(@as(usize, 1), fixture.draft.items.items.len);
    var history = try fixture.draft.freeze();
    defer history.deinit();
    click(cx, fixture.view.cards[0].preview);
    click(cx, fixture.view.preview_remove);
    try std.testing.expectEqual(ticket, fixture.removed.?);
    try std.testing.expectEqual(@as(usize, 0), fixture.draft.items.items.len);
    try std.testing.expect(!fixture.view.isPreviewOpen());
    try fixture.view.openSentPreview(history.items[0].reference);
    try std.testing.expect(fixture.view.isPreviewOpen());
    try std.testing.expectEqual(ui.types.Display.none, fixture.view.preview_remove.style.display);
    try std.testing.expectEqualStrings(pixel_png, fixture.view.preview_reference.content().?.bytes);
    try std.testing.expect(fixture.view.escapePreview());
}

test "AI images share one fixed-height horizontal rail with text attachments" {
    const text = @import("ui/ai_attachments_view.zig");
    const text_model = @import("ai/local_text_attachments.zig");
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 500);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    var draft = try images.Draft.init(a, .{ .session = 101 });
    defer draft.deinit();
    var text_draft = try text_model.Draft.init(a, .{ .session = 101 });
    defer text_draft.deinit();
    const holder = try ui.box(cx, .{}, .{});
    try cx.root.?.appendChild(a, holder);
    const text_view = try text.View.mountInline(cx, scope, .{ .context = &draft }, holder);
    try cx.root.?.appendChild(a, text_view.root);
    const image_view = try V.View.mount(cx, scope, .{ .context = &draft }, holder);
    try image_view.shareRail(text_view.rail.content);
    text_view.external_rail = image_view.root;
    for (0..4) |_| _ = try draft.begin("/selected.png", .{});
    try image_view.update(&draft);
    text_view.external_count = image_view.count;
    try text_view.update(&text_draft);
    settle(cx);
    try std.testing.expectEqual(@as(f32, 48), text_view.root.globalRect().h);
    const first = image_view.cards[0].root.globalRect();
    const last = image_view.cards[3].root.globalRect();
    try std.testing.expectEqual(first.y, last.y);
    try std.testing.expect(last.x > first.x + 500);
    // Rebuilding text cards must not destroy the externally owned image cards.
    const ticket = try text_draft.begin();
    var reference = try text_model.ContentRef.create(a, "/text.txt", "saved", 1);
    _ = try text_draft.complete(ticket, &reference);
    try text_view.update(&text_draft);
    settle(cx);
    try std.testing.expectEqual(@as(f32, 48), text_view.root.globalRect().h);
    try std.testing.expectEqual(@as(usize, 4), image_view.count);
}
