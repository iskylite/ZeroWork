const std = @import("std");
const ui = @import("ui");
const Controller = @import("config/settings_controller.zig").Controller;
const view = @import("config/settings_content_view.zig");
const values = @import("config/settings_values.zig");
const a = std.testing.allocator;
const Probe = struct {
    controller: *Controller,
    user_edits: usize = 0,
    help_reads: usize = 0,
    feedback_text: ?[]const u8 = null,
    feedback_on_edit: ?[]const u8 = null,
    status_label: ?*ui.Node = null,
    fn feedback(raw: *anyopaque) ?[]const u8 {
        const self: *Probe = @ptrCast(@alignCast(raw));
        return self.feedback_text;
    }
    fn changed(_: *anyopaque) void {}
    fn request(_: *anyopaque, _: view.Key, _: *ui.Node) void {}
    fn action(_: *anyopaque, _: view.Action) void {}
    fn edit(raw: *anyopaque, key: view.Key, value: values.Value) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.user_edits += 1;
        self.controller.editKey(key.section, key.key, value) catch unreachable;
        if (self.feedback_on_edit) |message| {
            self.feedback_text = message;
            if (self.status_label) |label| label.setTextContent(a, message) catch unreachable;
        }
    }
    fn help(raw: *anyopaque) []const u8 {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.help_reads += 1;
        return "系统通知已被拒绝，请在 macOS 系统设置中允许 ZeroWork 通知。";
    }
};
fn byId(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (byId(child, id)) |found| return found;
    return null;
}
test "notification actual settings switches call explicit user edit hook while mount and footer refresh do not" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    var controller = try Controller.init(a, .{});
    defer controller.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(636, 700);
    cx.root = try ui.box(cx, .{ .width = .{ .px = 636 }, .height = .{ .px = 700 } }, .{});
    controller.model.selectPage(6);
    var probe: Probe = .{ .controller = &controller };
    const mounted = try view.mountPage(cx, scope, &controller, .{ .context = &probe, .changed = Probe.changed, .request_edit = Probe.request, .action = Probe.action, .edit = Probe.edit, .authorization_help = Probe.help });
    try cx.root.?.appendChild(a, mounted.root);
    cx.layout();
    const help_reads_after_mount = probe.help_reads;
    try std.testing.expect(help_reads_after_mount > 0);
    mounted.refreshFooter();
    try std.testing.expectEqual(@as(usize, 0), probe.user_edits);
    const field = byId(mounted.root, "settings.field.transfer_done").?;
    const rect = field.globalRect();
    cx.handleMouseDownEx(rect.x + rect.w / 2, rect.y + rect.h / 2, .left, .{});
    cx.handleMouseUpEx(rect.x + rect.w / 2, rect.y + rect.h / 2, .left, .{});
    try std.testing.expectEqual(@as(usize, 1), probe.user_edits);
    try std.testing.expect(controller.model.value.notify.transfer_done);
    try std.testing.expect(!controller.original.value.notify.transfer_done);
    cx.handleMouseDownEx(rect.x + rect.w / 2, rect.y + rect.h / 2, .left, .{});
    cx.handleMouseUpEx(rect.x + rect.w / 2, rect.y + rect.h / 2, .left, .{});
    try std.testing.expectEqual(@as(usize, 2), probe.user_edits);
    try std.testing.expect(!controller.model.value.notify.transfer_done);
    mounted.refreshFooter();
    try std.testing.expectEqual(@as(usize, 2), probe.user_edits);
    try std.testing.expectEqual(help_reads_after_mount, probe.help_reads);
}

test "notification actual switch preserves waiting and failed authorization feedback through field footer refresh" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    var controller = try Controller.init(a, .{});
    defer controller.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(636, 700);
    cx.root = try ui.box(cx, .{ .width = .{ .px = 636 }, .height = .{ .px = 700 } }, .{});
    controller.model.selectPage(6);
    try controller.editKey("notify", "transfer_done", .{ .boolean = false });
    var probe: Probe = .{ .controller = &controller, .feedback_on_edit = "正在等待系统通知授权结果…" };
    const mounted = try view.mountPage(cx, scope, &controller, .{ .context = &probe, .changed = Probe.changed, .request_edit = Probe.request, .action = Probe.action, .edit = Probe.edit, .authorization_feedback = Probe.feedback });
    probe.status_label = mounted.status_label;
    try cx.root.?.appendChild(a, mounted.root);
    cx.layout();
    const rect = byId(mounted.root, "settings.field.transfer_done").?.globalRect();
    cx.handleMouseDownEx(rect.x + rect.w / 2, rect.y + rect.h / 2, .left, .{});
    cx.handleMouseUpEx(rect.x + rect.w / 2, rect.y + rect.h / 2, .left, .{});
    try std.testing.expectEqual(@as(usize, 1), probe.user_edits);
    try std.testing.expect(controller.model.value.notify.transfer_done);
    try std.testing.expectEqualStrings("正在等待系统通知授权结果…", mounted.status_label.getText().?.content);
    probe.feedback_text = "系统通知授权请求失败";
    mounted.refreshFooter();
    try std.testing.expectEqualStrings("系统通知授权请求失败", mounted.status_label.getText().?.content);
    const rebuilt = try view.mountPage(cx, scope, &controller, .{ .context = &probe, .changed = Probe.changed, .request_edit = Probe.request, .action = Probe.action, .authorization_feedback = Probe.feedback });
    try cx.root.?.appendChild(a, rebuilt.root);
    try std.testing.expectEqualStrings("系统通知授权请求失败", rebuilt.status_label.getText().?.content);
    controller.model.selectPage(7);
    mounted.refreshFooter();
    try std.testing.expect(!std.mem.eql(u8, "系统通知授权请求失败", mounted.status_label.getText().?.content));
}
