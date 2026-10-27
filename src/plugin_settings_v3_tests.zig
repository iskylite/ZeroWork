const std = @import("std");
const ui = @import("ui");
const view = @import("config/settings_content_view.zig");
const registry = @import("host/plugin_registry.zig");
fn changed(_: *anyopaque) void {}
fn request(_: *anyopaque, _: view.Key, _: *ui.Node) void {}
fn action(_: *anyopaque, _: view.Action) void {}
fn byId(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (byId(child, id)) |found| return found;
    return null;
}
fn hasText(node: *ui.Node, expected: []const u8) bool {
    if (node.getText()) |value| if (std.mem.eql(u8, value.content, expected)) return true;
    for (node.children.items) |child| if (hasText(child, expected)) return true;
    return false;
}
test "plugin V3 reads registered metadata and detail actions preserve draft" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.root = try ui.box(cx, .{}, .{});
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var controller = try @import("config/settings_controller.zig").Controller.init(std.testing.allocator, .{});
    defer controller.deinit();
    const entries = [_]registry.PluginManifest{
        .{ .id = "ssh", .display_name = "SSH", .plugin_version = "9.8.7", .origin = .builtin, .workspace_kind = "terminal", .content_renderer = "terminal" },
        .{ .id = "probe", .display_name = "Real registered probe", .plugin_version = "0.3.1", .origin = .bundled, .workspace_kind = "canvas", .content_renderer = "canvas", .settings_section = .{ .fields = &.{.{ .key = "show_grid", .label = "显示网格", .kind = .boolean, .default_value = "true", .apply_timing = .next_connection }} } },
    };
    controller.plugin_page.registry_source = .{ .published = .{ .entries = &entries, .renderers = &.{} } };
    controller.model.selectPage(5);
    try controller.editKey("ui", "font_size", .{ .unsigned = 19 });
    var context: u8 = 0;
    const content = try view.mountContent(cx, scope, &controller, .{ .context = &context, .changed = changed, .request_edit = request, .action = action });
    try cx.root.?.appendChild(cx.allocator, content);
    const timing = byId(content, "settings.plugin.probe.show_grid.timing").?;
    try std.testing.expect(timing.behavior.interaction.focusable);
    try std.testing.expectEqualStrings("下次连接生效", timing.behavior.interaction.a11y.?.label.?);
    try std.testing.expect(!hasText(content, "下次连接生效"));
    const row = byId(content, "settings.plugin.ssh.row").?;
    try std.testing.expectEqual(@as(f32, 66), row.style.height.px);
    try std.testing.expectEqualStrings("远程终端、认证与端口转发", byId(content, "settings.plugin.ssh.description").?.getText().?.content);
    const button = byId(content, "settings.plugin.ssh.version").?;
    try std.testing.expect(hasText(button, "9.8.7"));
    const click = button.behavior.events.on_click.?;
    click.callback(click.context);
    try std.testing.expectEqual(@as(u16, 19), controller.model.value.ui.font_size);
    const close = byId(cx.root.?, "settings.plugin.ssh.version.close").?;
    const close_click = close.behavior.events.on_click.?;
    close_click.callback(close_click.context);
    try std.testing.expectEqual(@as(u16, 19), controller.model.value.ui.font_size);
    try std.testing.expectEqualStrings("静态链接插件随应用管理", byId(cx.root.?, "settings.plugin.ssh.version.message").?.getText().?.content);
    // Unknown plugins disclose only their actual metadata; there is no invented capability.
    try std.testing.expectEqualStrings("canvas", @import("config/settings_parts/settings_plugins.zig").description(entries[1]));
    try std.testing.expectEqualStrings("连接时按需请求权限", @import("config/settings_parts/settings_plugins.zig").permissions(entries[1]));
}
