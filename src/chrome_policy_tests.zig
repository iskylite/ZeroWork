const std = @import("std");
const ui = @import("ui");
const theme = @import("ui/app_theme.zig");

test "chromeless controls keep keyboard focus visible with fill and restore on blur in every theme" {
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setTheme(theme.widgetTheme(name));
        cx.setViewport(480, 160);
        const scope = try ui.Scope.init(cx.allocator, null, cx.owner);
        defer scope.dispose();
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        const button = try ui.widgets.Button(.{ .label = "当前会话传输", .variant = .ghost }).mount(scope, cx);
        try cx.root.?.appendChild(cx.allocator, button);
        cx.layout();
        _ = cx.render();
        const resting = button.getBackground();
        cx.clearFocus();
        cx.setFocus(button);
        try cx.setTestFrameStep(16);
        for (0..20) |_| {
            cx.advanceFrameClock();
            cx.layout();
            _ = cx.render();
        }
        try std.testing.expect(button.style.outline() == null);
        try std.testing.expectEqual(cx.tokens.tokens.color.bg_active, button.getBackground());
        try std.testing.expect(cx.isFocused(button));
        cx.clearFocus();
        for (0..20) |_| {
            cx.advanceFrameClock();
            cx.layout();
            _ = cx.render();
        }
        try std.testing.expectEqual(resting, button.getBackground());
        try std.testing.expect(button.style.outline() == null);
        // Mouse focus can begin while the hover transition is already painted.
        const rect = button.globalRect();
        cx.handleMouseMove(rect.x + rect.w / 2, rect.y + rect.h / 2);
        for (0..20) |_| {
            cx.advanceFrameClock();
            _ = cx.render();
        }
        cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
        cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
        cx.handleMouseMove(470, 150);
        cx.clearFocus();
        for (0..20) |_| {
            cx.advanceFrameClock();
            _ = cx.render();
        }
        try std.testing.expectEqual(resting, button.getBackground());
    }
}

test "chromeless primary and danger focus preserve a readable solid action background" {
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        inline for (.{ .primary, .danger }) |variant| {
            const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
            defer cx.deinit();
            cx.setTheme(theme.widgetTheme(name));
            cx.setViewport(480, 160);
            const scope = try ui.Scope.init(cx.allocator, null, cx.owner);
            defer scope.dispose();
            cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
            const button = try ui.widgets.Button(.{ .label = "执行操作", .variant = variant }).mount(scope, cx);
            try cx.root.?.appendChild(cx.allocator, button);
            cx.layout();
            _ = cx.render();
            const resting = button.getBackground();
            cx.setFocus(button);
            try cx.setTestFrameStep(16);
            for (0..20) |_| {
                cx.advanceFrameClock();
                cx.layout();
                _ = cx.render();
            }
            const active = button.getBackground();
            try std.testing.expectEqual(@as(u8, 255), active.a);
            try std.testing.expectEqual(ui.Color.lerp(resting, ui.Color.BLACK, 0.12), active);
            try std.testing.expect(button.style.outline() == null);
            cx.clearFocus();
            for (0..20) |_| {
                cx.advanceFrameClock();
                cx.layout();
                _ = cx.render();
            }
            try std.testing.expectEqual(resting, button.getBackground());
        }
    }
}

test "chromeless input never restores a frame on hover focus typing or invalid state" {
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setTheme(theme.widgetTheme(name));
        cx.setViewport(480, 160);
        const scope = try ui.Scope.init(cx.allocator, null, cx.owner);
        defer scope.dispose();
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        const result = try ui.widgets.Input(.{ .placeholder = "搜索", .error_msg = "示例错误" }).mountResult(scope, cx);
        const input = result.node;
        try cx.root.?.appendChild(cx.allocator, input);
        cx.layout();
        _ = cx.render();
        const state = result.state;
        const resting_background = result.input_container.getBackground();
        cx.setFocus(result.input_container);
        cx.handleTextInput("value");
        _ = cx.render();
        const container = state.input_container_node.?;
        try std.testing.expectEqual(@as(u8, 0), container.style.border.color.a);
        try std.testing.expect(state.focused);
        try std.testing.expectEqual(cx.tokens.tokens.color.bg_active, container.getBackground());
        if (state.focus_ring_host) |host| try std.testing.expect(host.style.outline() == null);
        cx.clearFocus();
        _ = cx.render();
        try std.testing.expectEqual(@as(u8, 0), container.style.border.color.a);
        try std.testing.expectEqual(resting_background, container.getBackground());
    }
}

test "chromeless grouped input keeps the actual field filled without creating an outline" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setTheme(theme.widgetTheme(.dark));
    cx.setViewport(480, 160);
    const scope = try ui.Scope.init(cx.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const group = try ui.widgets.Group(.{}).mount(scope, cx);
    try cx.root.?.appendChild(cx.allocator, group.container);
    const result = try ui.widgets.Input(.{ .value = "host", .width = 200 }).mountResult(scope, cx);
    try ui.widgets.group.addGroupItem(group.container, cx.allocator, result.node, .first, 8);
    cx.layout();
    _ = cx.render();
    cx.setFocus(result.input_container);
    _ = cx.render();
    try std.testing.expect(result.state.grouped_attached);
    try std.testing.expect(result.state.focus_ring_host.?.style.outline() == null);
    try std.testing.expect(result.input_container.style.outline() == null);
    try std.testing.expectEqual(cx.tokens.tokens.color.bg_active, result.input_container.getBackground());
    cx.clearFocus();
}

test "chromeless input disable cancels composition restores disabled surface and rejects editing" {
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setTheme(theme.widgetTheme(name));
        cx.setViewport(480, 160);
        const scope = try ui.Scope.init(cx.allocator, null, cx.owner);
        defer scope.dispose();
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        const disabled = try scope.createSignal(bool, false);
        const result = try ui.widgets.Input(.{ .disabled = disabled, .value = "saved" }).mountResult(scope, cx);
        try cx.root.?.appendChild(cx.allocator, result.node);
        cx.layout();
        _ = cx.render();
        cx.setFocus(result.input_container);
        cx.handleImePreedit("候选", 6);
        disabled.set(true);
        _ = cx.render();
        try std.testing.expect(!result.state.focused);
        try std.testing.expect(!result.state.imeIsComposing());
        try std.testing.expect(cx.focus_manager.getFocused() == null);
        try std.testing.expect(result.input_container.style.outline() == null);
        try std.testing.expect(result.input_container.behavior.interaction.a11y.?.disabled);
        try std.testing.expectEqual(@as(u8, 0), result.input_container.style.border.color.a);
        try std.testing.expectEqual(cx.tokens.tokens.color.bg_secondary, result.input_container.getBackground());
        cx.handleTextInput("blocked");
        try std.testing.expectEqualStrings("saved", result.value.?.peek());
        disabled.set(false);
        cx.setFocus(result.input_container);
        cx.handleTextInput("x");
        try std.testing.expect(std.mem.indexOf(u8, result.value.?.peek(), "x") != null);
        cx.clearFocus();
    }
}

test "chromeless textarea uses its visible field for focus and keeps errors disabled and blur frameless" {
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setTheme(theme.widgetTheme(name));
        cx.setViewport(480, 240);
        const scope = try ui.Scope.init(cx.allocator, null, cx.owner);
        defer scope.dispose();
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        const disabled = try scope.createSignal(bool, false);
        const result = try ui.widgets.Textarea(.{ .disabled = disabled, .value = "saved", .error_msg = "错误信息", .rows = 2 }).mountResult(scope, cx);
        try cx.root.?.appendChild(cx.allocator, result.wrapper);
        cx.layout();
        _ = cx.render();
        const resting = result.input.getBackground();
        try std.testing.expectEqual(@as(u8, 0), result.input.style.border.color.a);
        try std.testing.expect(result.input.behavior.interaction.a11y.?.invalid);
        cx.setFocus(result.input);
        _ = cx.render();
        try std.testing.expectEqual(cx.tokens.tokens.color.bg_active, result.input.getBackground());
        try std.testing.expect(result.input.style.outline() == null);
        try std.testing.expect(result.state.focus_ring_host.?.style.outline() == null);
        cx.clearFocus();
        _ = cx.render();
        try std.testing.expectEqual(resting, result.input.getBackground());
        cx.setFocus(result.input);
        disabled.set(true);
        _ = cx.render();
        try std.testing.expect(!result.state.focused);
        try std.testing.expectEqual(cx.tokens.tokens.color.bg_secondary, result.input.getBackground());
        try std.testing.expectEqual(@as(u8, 0), result.input.style.border.color.a);
        try std.testing.expect(result.input.style.outline() == null);
    }
}
