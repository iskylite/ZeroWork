const std = @import("std");
const ui = @import("ui");
const picker = @import("config/settings_picker.zig");
const Controller = @import("config/settings_controller.zig").Controller;
fn call(_: *anyopaque) void {}
fn dir(_: *anyopaque, _: *Controller, _: picker.Key) void {}
test "picker numeric validation preserves original on compound failure" {
    var controller = try Controller.init(std.testing.allocator, .{});
    defer controller.deinit();
    try std.testing.expectError(error.OutOfRange, picker.commit(&controller, .{ .section = "ui", .key = "font_size" }, "49"));
    try std.testing.expectError(error.InvalidValue, picker.commit(&controller, .{ .section = "ui", .key = "line_height" }, "nan"));
    try std.testing.expectError(error.OutOfRange, picker.commit(&controller, .{ .section = "transfer", .key = "window_chunks" }, "8 × 0"));
    try std.testing.expectEqual(@as(u8, 16), controller.model.value.transfer.window_chunks);
    try picker.commit(&controller, .{ .section = "transfer", .key = "window_chunks" }, "8 × 32");
    try std.testing.expectEqual(@as(u8, 8), controller.model.value.transfer.window_chunks);
    try std.testing.expectEqual(@as(u16, 32), controller.model.value.transfer.chunk_kb);
}
test "anchored picker mounts and disposes without borrowed editing buffers" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var controller = try Controller.init(std.testing.allocator, .{});
    defer controller.deinit();
    var context: u8 = 0;
    const anchor = try ui.box(cx, .{}, .{});
    try root.appendChild(cx.allocator, anchor);
    const mounted = try picker.mount(cx, scope, root, anchor, &controller, .{ .section = "ui", .key = "font_family" }, .{ .context = &context, .committed = call, .dismiss = call, .choose_directory = dir });
    try root.appendChild(cx.allocator, mounted.root);
    var font = [_]u8{ 'M', 'e', 'n', 'l', 'o' };
    try picker.commit(&controller, .{ .section = "ui", .key = "font_family" }, &font);
    @memset(&font, 'x');
    try std.testing.expectEqualStrings("Menlo", controller.model.value.ui.font_family);
}

test "picker measured height flips above bottom anchor and follows resized card" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 230);
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var c = try Controller.init(std.testing.allocator, .{});
    defer c.deinit();
    var context: u8 = 0;
    const a = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 290 }, .top = .{ .px = 200 } }, .width = .{ .px = 24 }, .height = .{ .px = 20 } }, .{});
    try root.appendChild(cx.allocator, a);
    const p = try picker.mount(cx, scope, root, a, &c, .{ .section = "ui", .key = "font_family" }, .{ .context = &context, .committed = call, .dismiss = call, .choose_directory = dir });
    try root.appendChild(cx.allocator, p.root);
    _ = cx.render();
    const rect = p.root.globalRect();
    try std.testing.expect(rect.x + rect.w <= 312.5);
    try std.testing.expect(rect.y + rect.h <= a.globalRect().y - 3.5);
    cx.setViewport(260, 180);
    a.style.ensureExtPanic(cx.allocator).inset.left = .{ .px = 230 };
    a.style.ensureExtPanic(cx.allocator).inset.top = .{ .px = 150 };
    a.markLayoutDirty();
    cx.frame_count += 1;
    cx.frame_time_ms += 16;
    _ = cx.render();
    const next = p.root.globalRect();
    try std.testing.expect(next.x + next.w <= 252.5);
    try std.testing.expect(next.y >= 7.5 and next.y + next.h <= 172.5);
}

test "key recorder uses measured bounds in short card" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(270, 110);
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var map: @import("config/keybindings.zig").Map = .{};
    var context: u8 = 0;
    const anchor = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 240 }, .top = .{ .px = 85 } }, .width = .{ .px = 20 }, .height = .{ .px = 20 } }, .{});
    try root.appendChild(cx.allocator, anchor);
    const p = try @import("config/keybinding_picker.zig").mount(cx, scope, root, anchor, &map, "搜索当前终端", .{ .context = &context, .changed = call, .dismiss = call });
    try root.appendChild(cx.allocator, p.root);
    _ = cx.render();
    const r = p.root.globalRect();
    try std.testing.expect(r.x + r.w <= 262.5);
    try std.testing.expect(r.y + r.h <= anchor.globalRect().y - 3.5);
}

test "short picker scroll exposes final choice and numeric input receives focus" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 100);
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var c = try Controller.init(std.testing.allocator, .{});
    defer c.deinit();
    var context: u8 = 0;
    const anchor = try ui.box(cx, .{ .width = .{ .px = 25 }, .height = .{ .px = 20 } }, .{});
    try root.appendChild(cx.allocator, anchor);
    const p = try picker.mount(cx, scope, root, anchor, &c, .{ .section = "ui", .key = "font_family" }, .{ .context = &context, .committed = call, .dismiss = call, .choose_directory = dir });
    try root.appendChild(cx.allocator, p.root);
    for (0..3) |_| {
        cx.frame_count += 1;
        cx.frame_time_ms += 16;
        _ = cx.render();
    }
    try std.testing.expect(p.root.globalRect().h <= 84.5);
    const choice = p.body.content.children.items[2];
    ui.widgets.setScrollY(p.body.state, p.body.content, p.body.state.maxScrollY());
    cx.frame_count += 1;
    cx.frame_time_ms += 16;
    _ = cx.render();
    const cr = choice.globalRect();
    const vr = p.body.container.globalRect();
    try std.testing.expect(cr.y + cr.h > vr.y and cr.y < vr.y + vr.h);
    const click = choice.behavior.events.on_click.?;
    click.callback(click.context);
    try std.testing.expectEqualStrings("Monaco", c.model.value.ui.font_family);
    const numeric = try picker.mount(cx, scope, root, anchor, &c, .{ .section = "ui", .key = "font_size" }, .{ .context = &context, .committed = call, .dismiss = call, .choose_directory = dir });
    try root.appendChild(cx.allocator, numeric.root);
    for (0..3) |_| {
        cx.frame_count += 1;
        cx.frame_time_ms += 16;
        _ = cx.render();
    }
    try std.testing.expect(cx.focus_manager.getFocused() == numeric.input_node.?);
}
