test {
    _ = @import("ui/group_close_controller.zig");
}

const std = @import("std");
const ui = @import("ui");

fn findCloseAction(node: *ui.Node) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |id| if (std.mem.eql(u8, id, "groups.close.accept")) return node;
    for (node.children.items) |child| if (findCloseAction(child)) |found| return found;
    return null;
}

noinline fn overwriteStack() void {
    var bytes: [8192]u8 = undefined;
    @memset(&bytes, 0);
    std.mem.doNotOptimizeAway(&bytes);
}

test "group close action owns its dynamic accessibility label after render returns" {
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setTheme(@import("ui/app_theme.zig").widgetTheme(.dark));
    cx.setViewport(1000, 700);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const dialog = try ui.box(cx, .{}, .{});
    cx.root = dialog;
    const body = try ui.box(cx, .{}, .{});
    try dialog.appendChild(a, body);
    var plan: @import("ui/group_close_controller.zig").Plan = .{};
    defer plan.deinit(a);
    try plan.append(a, .{ .id = 1, .generation = 1 });
    try plan.append(a, .{ .id = 2, .generation = 1 });
    const callback = struct {
        fn noop(_: *anyopaque) void {}
    };
    _ = try @import("ui/group_close_view.zig").render(cx, scope, dialog, body, .{
        .group_name = "test-group",
        .plan = &plan,
        .partial = false,
        .cancel = .{ .context = &plan, .callback = callback.noop },
        .approve = .{ .context = &plan, .callback = callback.noop },
    });
    const action = findCloseAction(dialog).?;
    overwriteStack();
    cx.layout();
    try std.testing.expectEqualStrings("关闭全部 2 个会话", action.behavior.interaction.a11y.?.label.?);
    const theme = @import("ui/app_theme.zig");
    const previous = theme.currentName();
    defer theme.select(previous);
    for (@import("config/theme_presets.zig").ids) |id| {
        theme.selectTokens(@import("config/theme_registry.zig").builtinTokens(id));
        try @import("ui_theme_test_support.zig").publish(cx, scope);
        try cx.setTestFrameStep(16);
        for (0..24) |_| {
            cx.advanceFrameClock();
            _ = cx.render();
        }
        try std.testing.expectEqual(theme.current().overlay, dialog.getBackground());
        try std.testing.expectEqual(theme.current().action_danger, action.getBackground());
        try std.testing.expectEqualStrings("关闭全部 2 个会话", action.behavior.interaction.a11y.?.label.?);
        try std.testing.expectEqual(@as(usize, 2), plan.members.items.len);
    }
}
