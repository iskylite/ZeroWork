const std = @import("std");
const ui = @import("ui");
const styles = @import("ui/shell_styles.zig");
const theme = @import("ui/app_theme.zig");
const Chrome = @FieldType(@FieldType(@import("zenit_app").App, "chrome"), "initial");

test "fullscreen titlebar follows visible native controls through enter exit and maximize" {
    const Case = struct { chrome: Chrome, left: f32 };
    for ([_]Case{
        .{ .chrome = .{ .native_controls_count = 3 }, .left = 79 },
        .{ .chrome = .{ .maximized = true, .native_controls_count = 3 }, .left = 79 },
        .{ .chrome = .{ .fullscreen_transitioning = true, .native_controls_count = 3 }, .left = 79 },
        .{ .chrome = .{ .fullscreen = true, .fullscreen_transitioning = true }, .left = 10 },
        .{ .chrome = .{ .fullscreen = true }, .left = 10 },
        .{ .chrome = .{ .fullscreen_transitioning = true }, .left = 10 },
        .{ .chrome = .{ .native_controls_count = 3 }, .left = 79 },
        // Unknown geometry stays conservative in windowed mode. Fullscreen
        // is observed state, never a requested action or the maximized flag.
        .{ .chrome = .{ .controls_geometry_known = false }, .left = 79 },
        .{ .chrome = .{ .controls_geometry_known = false, .fullscreen = true }, .left = 10 },
    }) |case| {
        const padding = styles.titlePaddingForChrome(case.chrome);
        try std.testing.expectEqual(case.left, padding.left);
        try std.testing.expectEqual(@as(f32, 10), padding.right);
    }
}

const Hook = struct {
    cx: *ui.Cx,
    bar: *ui.Node,
    chrome: Chrome = .{ .native_controls_count = 3 },
    fn run(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return if (styles.syncTitleChrome(self.cx.allocator, self.bar, self.chrome)) .needs_layout else .done;
    }
    fn frame(self: *@This()) void {
        self.cx.frame_count += 1;
        self.cx.frame_time_ms += 16;
        _ = self.cx.render();
    }
};

test "fullscreen titlebar retains children focus and window isolation across theme publication and resize" {
    const saved = theme.currentName();
    defer theme.select(saved);
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    const other_cx = try ui.Cx.init(allocator, std.testing.io);
    defer other_cx.deinit();
    cx.setViewport(1440, 900);
    other_cx.setViewport(1000, 700);
    const publication = try cx.bindState(styles.ThemePublication, .{});
    publication.publish(cx, theme.widgetTheme(saved));
    const root = try ui.boxStyled(cx, styles.root, .{});
    cx.root = root;
    const bar = try ui.boxStyled(cx, styles.title, .{});
    try root.appendChild(allocator, bar);
    const controls = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row }, .{});
    try bar.appendChild(allocator, controls);
    const tab = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    tab.setFocusable(true);
    try controls.appendChild(allocator, tab);
    const other_bar = try ui.boxStyled(other_cx, styles.title, .{});
    other_cx.root = other_bar;
    var hook: Hook = .{ .cx = cx, .bar = bar };
    var other: Hook = .{ .cx = other_cx, .bar = other_bar };
    try cx.addAfterLayoutHook(&hook, Hook.run);
    defer cx.removeAfterLayoutHook(&hook);
    try other_cx.addAfterLayoutHook(&other, Hook.run);
    defer other_cx.removeAfterLayoutHook(&other);
    hook.frame();
    other.frame();
    cx.setFocus(tab);
    try std.testing.expectApproxEqAbs(@as(f32, 87), tab.globalRect().x, 0.01);
    const bar_id = bar.id;
    const tab_id = tab.id;
    hook.chrome = .{ .fullscreen = true };
    cx.requestRedraw();
    hook.frame();
    try std.testing.expectApproxEqAbs(@as(f32, 18), tab.globalRect().x, 0.01);
    // Theme publication replays boxStyled defaults. The same safe hook must
    // restore native-state padding before the frame is presented.
    theme.select(.light);
    publication.publish(cx, theme.widgetTheme(.light));
    cx.setViewport(1728, 1117);
    hook.frame();
    try std.testing.expectEqual(@as(f32, 10), bar.style.padding.left);
    try std.testing.expectApproxEqAbs(@as(f32, 18), tab.globalRect().x, 0.01);
    try std.testing.expectEqual(bar_id, bar.id);
    try std.testing.expectEqual(tab_id, controls.children.items[0].id);
    try std.testing.expectEqual(tab, cx.focused_node.?);
    try std.testing.expectEqual(@as(f32, 79), other_bar.style.padding.left);
    try std.testing.expect(!styles.syncTitleChrome(allocator, bar, hook.chrome));
    hook.chrome = .{ .native_controls_count = 3 };
    cx.setViewport(1440, 900);
    hook.frame();
    try std.testing.expectApproxEqAbs(@as(f32, 87), tab.globalRect().x, 0.01);
    try std.testing.expectEqual(tab, cx.focused_node.?);
    try std.testing.expectEqual(tab_id, controls.children.items[0].id);
    // The second window deliberately has no tabs; its own fullscreen state
    // still changes the title inset independently.
    other.chrome = .{ .fullscreen = true };
    other_cx.requestRedraw();
    other.frame();
    try std.testing.expectEqual(@as(f32, 10), other_bar.style.padding.left);
    try std.testing.expectEqual(@as(f32, 79), bar.style.padding.left);
}
