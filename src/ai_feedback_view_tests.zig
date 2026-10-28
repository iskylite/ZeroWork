const std = @import("std");
const ui = @import("ui");
const Feedback = @import("ui/ai_feedback_view.zig");
const theme = @import("ui/app_theme.zig");
const a = std.testing.allocator;

test "AI feedback stays in scroll flow and preserves composer bounds with long text" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(600, 358);
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const scroll = try ui.widgets.ScrollArea(.{ .height = 200, .direction = .vertical }).mount(scope, cx);
    scroll.container.setStyleInline(a, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 });
    try root.appendChild(a, scroll.container);
    const feedback = try Feedback.View.mount(cx, scope);
    try scroll.content.appendChild(a, feedback.root);
    const composer = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 90 }, .flex_shrink = 0 }, .{});
    try root.appendChild(a, composer);
    for ([_]f32{ 600, 320 }) |width| {
        cx.setViewport(width, 358);
        feedback.show("", .warning);
        cx.layout();
        const before = composer.globalRect();
        feedback.show(Feedback.rollback_label, .rollback);
        cx.layout();
        try std.testing.expectEqual(before, composer.globalRect());
        try std.testing.expect(feedback.rollback_icon.isDisplayedInTree());
        try std.testing.expect(!feedback.warning_icon.isDisplayedInTree());
        try std.testing.expectEqual(theme.current().fg_2, feedback.text.getText().?.color);
        const close = feedback.dismiss_button.globalRect();
        const text = feedback.text.globalRect();
        try std.testing.expect(text.x + text.w <= close.x);
        try std.testing.expect(close.x + close.w <= width - 14);
        try std.testing.expect(text.h > 0);
        // A path with no whitespace must wrap within the content width.
        var path: [1600]u8 = undefined;
        @memset(&path, 'x');
        feedback.show(&path, .warning);
        for (0..3) |_| cx.layout();
        try std.testing.expectEqual(before, composer.globalRect());
        try std.testing.expect(feedback.warning_icon.isDisplayedInTree());
        try std.testing.expect(!feedback.dismiss_button.isDisplayedInTree());
        const long_text = feedback.text.globalRect();
        try std.testing.expect(long_text.x + long_text.w <= width - 24 + 0.1);
        try std.testing.expect(long_text.h > 36);
        try std.testing.expect(feedback.root.globalRect().h >= long_text.h + 16);
        feedback.show(Feedback.rollback_label, .rollback);
        cx.layout();
        feedback.dismiss_button.behavior.events.on_click.?.invoke();
        cx.layout();
        try std.testing.expect(!feedback.root.isDisplayedInTree());
        try std.testing.expectEqual(before, composer.globalRect());
    }
}
