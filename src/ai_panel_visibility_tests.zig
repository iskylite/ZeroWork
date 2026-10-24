//! Actual Cx hit testing after an AI ancestor is hidden while its descendants
//! continue receiving geometry/theme updates. No native window is created.
const std = @import("std");
const ui = @import("ui");
const S = @import("ui/ai_assistant_styles.zig");
const a = std.testing.allocator;

test "AI hidden panel descendants cannot intercept the underlying terminal input after geometry and text updates" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(1440, 900);
    try cx.setTestFrameStep(16);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const value = try scope.createText("", .{});
    const input = try ui.widgets.Textarea(.{ .value = value, .borderless = true, .rows = 45 }).mountResult(scope, cx);
    input.wrapper.setStyleInline(a, .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }, .width = .{ .px = 1440 }, .height = .{ .px = 900 } });
    input.input.setStyleInline(a, .{ .width = .fill(), .height = .fill() });
    try cx.root.?.appendChild(a, input.wrapper);
    const outer = try ui.box(cx, .{ .position = .absolute, .z_index = 200, .width = .{ .px = 600 }, .inset = .{ .left = .{ .px = 535 }, .top = .{ .px = 80 } }, .direction = .row }, .{});
    const card = try ui.boxStyled(cx, S.panel, .{});
    const body = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 276 } }, .{});
    const text = try ui.text(cx, "before hide", .{});
    try body.appendChild(a, text);
    try card.appendChild(a, body);
    try outer.appendChild(a, card);
    try cx.root.?.appendChild(a, outer);
    const Step = struct {
        fn frames(ctx: *ui.Cx) void {
            for (0..8) |_| {
                ctx.advanceFrameClock();
                _ = ctx.render();
            }
        }
        fn click(ctx: *ui.Cx, x: f32, y: f32) void {
            ctx.handleMouseDown(x, y, .{});
            ctx.handleMouseUp(x, y);
            frames(ctx);
        }
    };
    Step.frames(cx);
    // The visible opaque card intercepts the same point used after hiding.
    Step.click(cx, 600, 300);
    try std.testing.expect(cx.focus_manager.getFocused() != input.input);
    const Hidden = enum { display, opacity, hit_visible };
    for ([_]Hidden{ .display, .opacity, .hit_visible }, 0..) |mode, mode_index| {
        switch (mode) {
            .display => outer.setDisplay(.none),
            .opacity => outer.setOpacityRaw(0),
            .hit_visible => outer.setHitTestVisible(false),
        }
        Step.frames(cx);
        Step.click(cx, 1250, 700);
        try std.testing.expect(cx.focus_manager.getFocused() == input.input);
        // In-flow dirty descendants select their opaque card as a partial
        // interaction root. Rendering alone must preserve the hidden ancestor.
        body.setCursor(if (mode_index % 2 == 0) .pointer else .crosshair);
        Step.frames(cx);
        for ([_][2]f32{ .{ 600, 300 }, .{ 844, 460 } }) |point| {
            Step.click(cx, point[0], point[1]);
            try std.testing.expect(cx.focus_manager.getFocused() == input.input);
            cx.handleTextInput("pass");
        }
        // Match AppNavHost's continuing updates while the owner remains live.
        for (0..4) |index| {
            const width: f32 = 600 + @as(f32, @floatFromInt(index));
            card.setStyleInline(a, .{ .width = .{ .px = width }, .height = .{ .px = 420 } });
            body.setStyleInline(a, .{ .height = .{ .px = 276 } });
            try text.setTextContent(a, if (index % 2 == 0) "hidden geometry update" else "hidden text update");
            Step.frames(cx);
            Step.click(cx, 600, 300);
            try std.testing.expect(cx.focus_manager.getFocused() == input.input);
        }
        switch (mode) {
            .display => outer.setDisplay(.flex),
            .opacity => outer.setOpacityRaw(1),
            .hit_visible => outer.setHitTestVisible(true),
        }
        Step.frames(cx);
        body.setCursor(.inherit);
        Step.frames(cx);
        Step.click(cx, 600, 300);
        try std.testing.expect(cx.focus_manager.getFocused() != input.input);
        Step.click(cx, 1250, 700);
        try std.testing.expect(cx.focus_manager.getFocused() == input.input);
    }
    try std.testing.expectEqualStrings("passpasspasspasspasspass", value.peek());
}
