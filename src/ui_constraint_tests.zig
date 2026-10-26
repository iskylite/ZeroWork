//! Shared action recipes exercised with their real labels, icons and states.
const std = @import("std");
const ui = @import("ui");
const shell = @import("ui/shell_styles.zig");
const theme = @import("ui/app_theme.zig");
const quick = @import("ui/quick_connect_styles.zig");
const wizard = @import("ui/wizard_styles.zig");
const approval = @import("ui/ai_tool_approval_styles.zig");
const asset = @import("ui/asset_action_styles.zig");
const conflict = @import("ui/transfer_conflict_styles.zig");
const progress = @import("ui/connection_progress_styles.zig");
const cleanup = @import("ui/record_cleanup_styles.zig");
const transfer = @import("ui/transfer_styles.zig");
const empty = @import("ui/ai_empty_styles.zig");

fn frames(cx: *ui.Cx) void {
    for (0..12) |_| {
        cx.advanceFrameClock();
        _ = cx.render();
    }
}
fn checkText(cx: *ui.Cx, button: *ui.Node, node: *ui.Node, label: []const u8) !void {
    if (node.style.display == .none) return;
    const outer = button.globalRect();
    if (node.getText()) |text| {
        const rect = node.globalRect();
        const measured = cx.text.measureTextWidth(text.content, text.font_size, text.font_weight, false);
        const fits = rect.x >= outer.x - 0.5 and rect.y >= outer.y - 0.5 and rect.x + @max(rect.w, measured) <= outer.x + outer.w + 0.5 and rect.y + text.font_size * text.line_height <= outer.y + outer.h + 0.5;
        if (!fits) std.debug.print("\nAction overflow '{s}': button={any}, text={any}, width={d}, line={d}\n", .{ label, outer, rect, measured, text.font_size * text.line_height });
        try std.testing.expect(fits);
    }
    for (node.children.items) |child| try checkText(cx, button, child, label);
}

test "UI constraints action recipes contain full labels and preserve hit bounds when disabled" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.setTheme(theme.widgetTheme(.dark));
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const cases = .{
        .{ "Local Terminal", shell.emptyButton(true), true },
        .{ "选择连接", shell.emptyButton(false), false },
        .{ "连接所选主机", quick.button(true, false), false },
        .{ "连接临时目标", quick.button(true, true), false },
        .{ "保存并连接", wizard.button(116, 34, true), false },
        .{ "仅保存", wizard.button(88, 34, false), false },
        .{ "批准此调用", approval.iconButton(true), false },
        .{ "拒绝", approval.iconButton(false), false },
        .{ "批准执行", approval.groupButton(true), false },
        .{ "拒绝", approval.groupButton(false), false },
        .{ "确认移动", asset.button(120, 30, true, false), false },
        .{ "查看现有会话", asset.button(140, 30, false, false), false },
        .{ "覆盖远程文件", conflict.button(144, 34, true, true), false },
        .{ "返回选择", conflict.button(112, 34, false, false), false },
        .{ "重试连接", progress.button(112, 34, true), false },
        .{ "重试失败项", cleanup.button(true, false), false },
        .{ "打开传输管理器", transfer.v3FooterButton(true), false },
        .{ "打开 AI 设置", empty.setupAction(true), false },
        .{ "配置本地模型", empty.setupAction(false), false },
    };
    var failures: usize = 0;
    inline for (cases) |case| {
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        const disabled = try scope.createSignal(bool, false);
        const button = try ui.widgets.Button(.{ .label = @as([]const u8, case[0]), .icon_asset = if (case[2]) ui.icons.terminal else null, .icon_size = @as(f32, 17), .base_style = case[1], .disabled = disabled }).mount(scope, cx);
        try cx.root.?.appendChild(cx.allocator, button);
        frames(cx);
        const initial = button.globalRect();
        checkText(cx, button, button, case[0]) catch {
            failures += 1;
        };
        disabled.set(true);
        frames(cx);
        try std.testing.expectEqual(initial, button.globalRect());
        disabled.set(false);
        frames(cx);
        checkText(cx, button, button, case[0]) catch {
            failures += 1;
        };
        scope.dispose();
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |result| return result;
    return null;
}
const DirectoryProbe = struct {
    requests: usize = 0,
    fn changed(_: *anyopaque) void {}
    fn edit(raw: *anyopaque, _: @import("config/settings_content_view.zig").Key, _: *ui.Node) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.requests += 1;
    }
    fn action(_: *anyopaque, _: @import("config/settings_content_view.zig").Action) void {}
};

test "UI constraints long directory keeps a bounded label full tooltip and actual edit action" {
    const settings = @import("config/settings_content_view.zig");
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    var controller = try @import("config/settings_controller.zig").Controller.init(std.testing.allocator, .{});
    defer controller.deinit();
    const path = "/Users/fixture/Downloads/团队服务器归档与诊断输出/production-cluster-2026-10-26/very-long-download-destination";
    try controller.editKey("transfer", "download_dir", .{ .text = path });
    try controller.setSearch("默认下载目录");
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var probe: DirectoryProbe = .{};
    const mounted = try settings.mountPage(cx, scope, &controller, .{ .context = &probe, .changed = DirectoryProbe.changed, .request_edit = DirectoryProbe.edit, .action = DirectoryProbe.action });
    try cx.root.?.appendChild(cx.allocator, mounted.root);
    frames(cx);
    const button = find(mounted.root, "settings.field.download_dir").?;
    const label = find(button, "settings.directory.label").?;
    try std.testing.expectEqualStrings(path, label.getText().?.content);
    try std.testing.expectEqual(@as(@TypeOf(label.getText().?.text_overflow), .ellipsis), label.getText().?.text_overflow);
    const outer = button.globalRect();
    const value = label.globalRect();
    try std.testing.expect(value.x >= outer.x);
    try std.testing.expect(value.x + value.w <= outer.x + outer.w);
    try std.testing.expect(value.w < cx.text.measureTextWidth(path, 12, 400, false));
    try std.testing.expectEqualStrings(path, button.behavior.interaction.a11y.?.label.?);
    cx.setFocus(button);
    frames(cx);
    const tip = find(cx.root.?, "settings.directory.tooltip").?;
    try std.testing.expect(tip.globalRect().h > 24);
    try std.testing.expect(tip.globalRect().w <= @import("config/settings_styles.zig").geometry.help_width);
    try std.testing.expect(mounted.binding.consumeEscape());
    cx.handleMouseDown(outer.x + outer.w / 2, outer.y + outer.h / 2, .{});
    cx.handleMouseUp(outer.x + outer.w / 2, outer.y + outer.h / 2);
    frames(cx);
    try std.testing.expectEqual(@as(usize, 1), probe.requests);
}
