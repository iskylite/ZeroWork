const ui = @import("ui");
const V = @import("ui/ai_remote_picker.zig");

test "AI remote filename button stays inside its bounded table cell" {
    const std = @import("std");
    const Probe = struct {
        clicks: usize = 0,
        fn click(self: *@This()) void {
            self.clicks += 1;
        }
    };
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const cell = try ui.box(cx, .{ .width = .{ .px = 180 }, .height = .{ .px = 43 }, .direction = .row, .min_width = 0 }, .{});
    try cx.root.?.appendChild(allocator, cell);
    var probe: Probe = .{};
    const name = "very-long-remote-filename-that-must-not-paint-over-the-size-or-modified-time-column.txt";
    const filename = try V.filenameButton(scope, cx, name, cx.on(Probe, &probe, Probe.click));
    const button_node = filename.button;
    try cell.appendChild(allocator, button_node);
    cx.layout();
    const rect = button_node.globalRect();
    try std.testing.expectEqual(@as(f32, 180), rect.w);
    try std.testing.expectEqual(@as(f32, 32), rect.h);
    const label = filename.label;
    try std.testing.expect(label.getText().?.text_overflow == .ellipsis);
    try std.testing.expect(label.globalRect().x + label.globalRect().w <= rect.x + rect.w);
    try std.testing.expectEqualStrings(name, button_node.behavior.interaction.a11y.?.label.?);
    cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    try std.testing.expectEqual(@as(usize, 1), probe.clicks);
}

test {
    _ = @import("ui/ai_remote_reference.zig");
}
