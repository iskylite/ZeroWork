const std = @import("std");
const ui = @import("ui");
const host = @import("host/notification_host.zig");
const Presenter = @import("ui/notification_presenter.zig").Presenter;
const a = std.testing.allocator;

test "notification presenter bounds longest admitted content and all actions at minimum window" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    var notice_host: host.Host = .{ .allocator = a, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{}, .{}) };
    defer notice_host.coordinator.deinit();
    try notice_host.coordinator.registerDefinition(.{ .id = "audit.feedback", .category = .operation_result, .default_channels = .{ .system = false, .attention = false } });
    const view = try Presenter.mount(cx, scope, &notice_host, @fromBackingInt(1));
    const owner: host.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(1) } };
    var detail = cycled("long detail content with words and spaces ", 4096);
    @memset(detail[0..512], 'x'); // A long unbroken path/token must also wrap.
    const action_label = cycled("long action label with spaces ", 128);
    for (0..3) |index| {
        _ = try notice_host.coordinator.publishNotification(.{ .definition_id = "audit.feedback", .owner = .{ .window_id = 1, .content = owner }, .operation_id = index + 1, .event_revision = 1, .phase = .failed, .severity = .failure, .title = &cycled("Longest admitted title ", 256), .detail = &detail, .actions = &.{ .{ .kind = .view_result, .label = &action_label }, .{ .kind = .view_result, .label = &action_label }, .{ .kind = .view_result, .label = &action_label } } }, .{ .monotonic_ms = 1, .local_minute = 0 });
    }
    for (0..8) |_| {
        try view.update(1, true, owner, .{ .content = .{ .x = 0, .y = 0, .w = 860, .h = 480 } });
        cx.layout();
    }
    const rect = view.root.globalRect();

    try std.testing.expectEqual(@as(f32, 62), rect.y);
    try std.testing.expect(rect.y + rect.h <= 480);
    try std.testing.expect(view.content.globalRect().h > view.viewport.globalRect().h);
    for (view.slots) |slot| {
        const card = slot.root.globalRect();
        for (slot.actions) |action| {
            const button = action.root.globalRect();
            const label = action.label.globalRect();
            try std.testing.expect(button.x >= card.x and button.x + button.w <= card.x + card.w);
            try std.testing.expect(label.x >= button.x and label.x + label.w <= button.x + button.w + 0.5);
            try std.testing.expect(label.y >= button.y and label.y + label.h <= button.y + button.h + 0.5);
            try std.testing.expectEqualStrings(&action_label, action.label.getText().?.content);
        }
        try std.testing.expectEqualStrings(&detail, slot.detail.getText().?.content);
        const detail_layout = slot.detail.getLayoutOutput().artifacts.text_layout.?;
        try std.testing.expect(detail_layout.max_line_width <= slot.detail.globalRect().w + 0.5);
        try std.testing.expect(detail_layout.lines[detail_layout.line_count - 1].byte_end == detail.len);
    }
    const last = view.slots[2].actions[2].root;
    const before = last.globalRect().y;
    cx.handleScroll(.{ .x = rect.x + 20, .y = rect.y + 100, .dx = 0, .dy = -100000 });
    for (0..8) |_| {
        cx.layout();
        _ = cx.render();
    }
    const after = last.globalRect();
    try std.testing.expect(after.y < before);
    try std.testing.expect(after.y >= rect.y and after.y + after.h <= rect.y + rect.h + 0.5);
}

fn cycled(comptime text: []const u8, comptime length: usize) [length]u8 {
    var result: [length]u8 = undefined;
    for (&result, 0..) |*byte, index| byte.* = text[index % text.len];
    return result;
}
