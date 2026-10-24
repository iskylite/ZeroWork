const std = @import("std");
const ui = @import("ui");
const search = @import("ui/terminal_search.zig");

test "Figma terminal search mounts a 360 by 44 single row with native icon actions" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 450);
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var model = search.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.setSource("hit hit hit");
    try model.setQuery("hit");
    var view = try search.mount(cx, scope, &model, .{});
    try root.appendChild(cx.allocator, view.root);
    for (0..4) |_| {
        cx.frame_count += 1;
        cx.frame_time_ms += 16;
        _ = cx.render();
    }
    view.focus();
    _ = cx.render();
    const panel = view.root.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 360), panel.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 44), panel.h, 0.01);
    try std.testing.expectEqual(@as(f32, 14), view.root.style.border.radius);
    const input = view.input_result.input_container.globalRect();
    try std.testing.expectApproxEqAbs(panel.x + 6, input.x, 0.01);
    try std.testing.expectApproxEqAbs(panel.y + 6, input.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 222), input.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 32), input.h, 0.01);
    try std.testing.expectEqual(@as(f32, 12), view.input_result.state.font_size);
    const count = view.count.globalRect();
    try std.testing.expectApproxEqAbs(panel.x + 232, count.x, 0.01);
    try std.testing.expectApproxEqAbs(panel.y + 14, count.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 38), count.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 16), count.h, 0.01);
    try std.testing.expectEqual(@as(f32, 11), view.count.getText().?.font_size);
    try std.testing.expectEqualStrings("1/3", view.count.getText().?.content);
    const row = view.root.children.items[0];
    for (row.children.items[2..], 0..) |action, index| {
        const rect = action.globalRect();
        try std.testing.expectApproxEqAbs(panel.x + 274 + @as(f32, @floatFromInt(index)) * 28, rect.x, 0.01);
        try std.testing.expectApproxEqAbs(panel.y + 10, rect.y, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 24), rect.w, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 24), rect.h, 0.01);
        try std.testing.expectEqualStrings("Button", action.meta.ownership.meta.component_name.?);
        try std.testing.expect(action.behavior.interaction.focusable);
    }
}

test "mounted search shows real counts and releases event contexts" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var model = search.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.setSource("first hit\nsecond hit");
    try model.setQuery("hit");
    var view = try search.mount(cx, scope, &model, .{});
    try root.appendChild(cx.allocator, view.root);
    try std.testing.expectEqualStrings("1/2", view.count.getText().?.content);
    model.next();
    view.refresh();
    try std.testing.expectEqualStrings("2/2", view.count.getText().?.content);
    try model.setQuery("missing");
    view.refresh();
    try std.testing.expectEqualStrings("无匹配", view.count.getText().?.content);
}

test "search bar remains inside minimum pane after resize" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 220);
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var model = search.Model.init(std.testing.allocator);
    defer model.deinit();
    var view = try search.mount(cx, scope, &model, .{});
    try root.appendChild(cx.allocator, view.root);
    view.fitPane(320);
    cx.layout();
    var rect = view.root.globalRect();
    try std.testing.expect(rect.x >= 13.5 and rect.x + rect.w <= 306.5);
    cx.setViewport(800, 400);
    view.fitPane(800);
    cx.layout();
    rect = view.root.globalRect();
    try std.testing.expectEqual(@as(f32, 360), rect.w);
    try std.testing.expectEqual(@as(f32, 44), rect.h);
}

test "search native actions keep input composition and button keyboard activation separate" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 450);
    const scope = try ui.Scope.init(cx.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var model = search.Model.init(cx.allocator);
    defer model.deinit();
    try model.setSource("hit hit");
    try model.setQuery("hit");
    const Sink = struct {
        previous: usize = 0,
        next: usize = 0,
        close: usize = 0,
        fn previousClicked(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.previous += 1;
        }
        fn nextClicked(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.next += 1;
        }
        fn closeClicked(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.close += 1;
        }
    };
    var sink: Sink = .{};
    var view = try search.mount(cx, scope, &model, .{ .context = &sink, .on_next = Sink.nextClicked, .on_previous = Sink.previousClicked, .on_close = Sink.closeClicked });
    try root.appendChild(cx.allocator, view.root);
    for (0..4) |_| {
        cx.frame_count += 1;
        cx.frame_time_ms += 16;
        _ = cx.render();
    }
    view.focus();
    try std.testing.expect(view.input_result.state.focused);
    try std.testing.expectEqual(@as(f32, 0), view.focus_ring.style.border.width);
    try std.testing.expectEqual(@as(f32, 0), view.input_result.input_container.style.border.width);
    cx.handleImePreedit("ni", 2);
    try std.testing.expect(view.input_result.state.imeIsComposing());
    cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(@as(usize, 0), sink.next + sink.previous + sink.close);
    cx.handleKeyDown(.escape, .{});
    try std.testing.expectEqual(@as(usize, 0), sink.close);
    cx.handleImePreedit("", 0);
    cx.setFocus(view.actions[0]);
    try std.testing.expect(!view.input_result.state.focused);
    cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(@as(usize, 1), sink.previous);
    try std.testing.expectEqual(@as(usize, 0), sink.next);
    cx.setFocus(view.actions[2]);
    cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(@as(usize, 1), sink.close);
    try model.setQuery("");
    view.refresh();
    _ = cx.render();
    try std.testing.expect(!view.actions[0].behavior.interaction.focusable);
    try std.testing.expect(!view.actions[1].behavior.interaction.focusable);
    try std.testing.expect(view.actions[2].behavior.interaction.focusable);
}
