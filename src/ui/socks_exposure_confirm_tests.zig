const std = @import("std");
const ui = @import("ui");
const view_mod = @import("socks_exposure_confirm.zig");

const Sink = struct { confirms: usize = 0, cancels: usize = 0, bind: []const u8 = "" };
fn confirm(raw: *anyopaque, bind: []const u8) void {
    const s: *Sink = @ptrCast(@alignCast(raw));
    s.confirms += 1;
    s.bind = bind;
}
fn cancel(raw: *anyopaque) void {
    const s: *Sink = @ptrCast(@alignCast(raw));
    s.cancels += 1;
}

test "exposure confirmation mounts hidden, owns bind and confirms only by action" {
    var cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 600);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var sink = Sink{};
    const view = try view_mod.View.mount(cx, scope, .{ .context = @ptrCast(&sink), .confirm = confirm, .cancel = cancel });
    try root.appendChild(cx.allocator, view.root);
    try std.testing.expect(view.root.style.display == .none);
    var bind = "0.0.0.0".*;
    try view.show(&bind);
    bind[0] = '1';
    cx.layout();
    _ = view.updateGeometry();
    cx.layout();
    _ = view.updateGeometry();
    cx.layout();
    try std.testing.expect(view.root.style.display == .flex);
    try std.testing.expectEqualStrings("0.0.0.0", view.pending_bind.items);
    const key = view.card.behavior.events.on_key_down.?;
    try std.testing.expectEqual(ui.events.EventResult.stop, key(.@"return", .{}, view.card.behavior.events.key_context));
    try std.testing.expectEqual(@as(usize, 0), sink.confirms);
    try std.testing.expectEqual(ui.events.EventResult.stop, key(.escape, .{}, view.card.behavior.events.key_context));
    try std.testing.expectEqual(@as(usize, 1), sink.cancels);
    try view.show("0.0.0.0");
    const click = view.confirm_button.behavior.events.on_click.?;
    click.callback(click.context);
    try std.testing.expectEqual(@as(usize, 1), sink.confirms);
    try std.testing.expectEqualStrings("0.0.0.0", sink.bind);
}

test "short viewport constrains confirmation body" {
    var cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(420, 170);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var sink = Sink{};
    const view = try view_mod.View.mount(cx, scope, .{ .context = @ptrCast(&sink), .confirm = confirm, .cancel = cancel });
    try root.appendChild(cx.allocator, view.root);
    try view.show("0.0.0.0");
    cx.layout();
    _ = view.updateGeometry();
    cx.layout();
    _ = view.updateGeometry();
    cx.layout();
    try std.testing.expect(view.body.container.style.height == .px);
    try std.testing.expect(view.body.container.style.height.px <= 96);
    const rect = view.card.globalRect();
    try std.testing.expect(rect.x >= 0 and rect.y >= 0);
    try std.testing.expect(rect.x + rect.w <= 420 and rect.y + rect.h <= 170);
    // The full content is preserved in the scroll area instead of clipped away.
    try std.testing.expect(view.body.content.globalRect().h > view.body.container.globalRect().h);
    view.body.container.meta.per_frame.hooks.before_render.main.?(view.body.container);
    ui.widgets.setScrollY(view.body.state, view.body.content, 1000);
    cx.layout();
    try std.testing.expect(view.body.state.scroll_y > 0);
}
