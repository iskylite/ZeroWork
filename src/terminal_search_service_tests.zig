const std = @import("std");
const Adapter = @import("vt/ghostty_adapter.zig").Adapter;
const search = @import("vt/ghostty_search.zig");
const a = std.testing.allocator;

test "search snapshot copies full retained softwrapped UTF8 cells without moving viewport" {
    var adapter = try Adapter.init(a, 3, 8);
    defer adapter.destroy();
    const expected = "abcdef界e\u{301}👩‍💻XYZ";
    _ = try adapter.feed("\x1b[31m" ++ expected ++ "\x1b[0m\r\nhardline\r\n");
    for (0..40) |index| {
        var buffer: [64]u8 = undefined;
        _ = try adapter.feed(try std.fmt.bufPrint(&buffer, "row-{d:0>3} needle\r\n", .{index}));
    }
    var before = try adapter.copyProjection(a);
    defer before.deinit(a);
    try std.testing.expect(before.scrollback.viewport_offset > 0);
    var document = try search.capture(&adapter, a);
    defer document.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, document.text, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, document.text, "hardline") != null);
    try std.testing.expect(std.mem.indexOf(u8, document.text, "row-000 needle") != null);
    try std.testing.expect(std.mem.indexOf(u8, document.text, "row-039 needle") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, document.text, 0x1b) == null);
    try std.testing.expectEqual(before.scrollback.total_rows, document.rows.len);
    try std.testing.expect(document.spanAt(0).?.color != 0);
    const wide_at = std.mem.indexOf(u8, document.text, "界").?;
    try std.testing.expectEqual(@as(u16, 2), document.spanAt(wide_at).?.width);
    const combining_at = std.mem.indexOf(u8, document.text, "e\u{301}").?;
    try std.testing.expectEqualStrings("e\u{301}", document.text[document.spanAt(combining_at).?.start..document.spanAt(combining_at).?.end]);
    const emoji_at = std.mem.indexOf(u8, document.text, "👩‍💻").?;
    try std.testing.expectEqual(@as(u16, 2), document.spanAt(emoji_at).?.width);
    try std.testing.expectEqualStrings("👩‍💻", document.text[document.spanAt(emoji_at).?.start..document.spanAt(emoji_at).?.end]);
    const first = document.rows[document.spanAt(0).?.row];
    const wrapped = document.rows[document.spanAt(emoji_at).?.row];
    try std.testing.expectEqual(first.logical_id, wrapped.logical_id);
    var after = try adapter.copyProjection(a);
    defer after.deinit(a);
    try std.testing.expectEqual(before.scrollback, after.scrollback);
    for (after.visible_rows) |row| {
        try std.testing.expectEqual(row.id, document.rows[@intCast(after.scrollback.viewport_offset + row.viewport_y)].id);
    }
}

test "search snapshot stale source cannot create a hit anchor and retained anchors follow reflow" {
    const Controller = @import("vt/terminal_controller.zig").Controller;
    const Engine = @import("vt/engine.zig").VtEngine;
    const TextSlot = @import("vt/text_slot.zig").TextSlot;
    const identity = @import("host/identity.zig");
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(81), .generation = 2 };
    var adapter = try Adapter.init(a, 3, 8);
    defer adapter.destroy();
    var slot = try TextSlot.init(a, 4096);
    defer slot.deinit(a);
    var controller = try Controller.init(.{ .owner = owner, .engine = Engine.from(Adapter, &adapter), .text_slot = &slot });
    try controller.feedOutput(owner, 1, "start-界e\u{301}👩‍💻needle-end\r\n", 1);
    var document = try controller.searchSnapshot(owner, a);
    defer document.deinit(a);
    const point = document.point(std.mem.indexOf(u8, document.text, "needle").?).?;
    const anchor = try controller.createAnchor(owner, point);
    defer controller.releaseAnchor(anchor) catch {};
    const before = (try controller.resolveAnchor(anchor)).?;
    try controller.resizeApplied(owner, .{ .revision = 2, .cols = 13, .rows = 3 }, 2);
    try std.testing.expectError(error.StaleProjection, controller.createAnchor(owner, point));
    const after = (try controller.resolveAnchor(anchor)).?;
    try std.testing.expect(before.row != after.row or before.col != after.col);
    try controller.scroll(owner, .{ .anchor = anchor }, 3);
    var refreshed = try controller.searchSnapshot(owner, a);
    defer refreshed.deinit(a);
    const mapped = refreshed.point(std.mem.indexOf(u8, refreshed.text, "needle").?).?;
    try std.testing.expectEqual(after.row, mapped.row);
    try std.testing.expectEqual(after.col, mapped.col);
    const foreign: identity.SessionHandle = .{ .session_id = owner.session_id, .generation = owner.generation + 1 };
    try std.testing.expectError(error.StaleOwner, controller.searchSnapshot(foreign, a));
    try std.testing.expectError(error.StaleOwner, controller.createAnchor(foreign, mapped));
}
