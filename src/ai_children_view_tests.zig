const std = @import("std");
const ui = @import("ui");
const View = @import("ui/ai_children_view.zig").View;
const projection = @import("ai/child_projection.zig");
const identity = @import("host/identity.zig");
const theme = @import("ui/app_theme.zig");
const a = std.testing.allocator;
const Selection = struct {
    agent: ?identity.AgentId = null,
    revision: u64 = 0,
    fn select(raw: *anyopaque, agent: identity.AgentId, revision: u64) void {
        const self: *Selection = @ptrCast(@alignCast(raw));
        self.* = .{ .agent = agent, .revision = revision };
    }
};
fn find(node: *ui.Node, key: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, key)) return node;
    for (node.children.items) |child| if (find(child, key)) |found| return found;
    return null;
}
test "v0.4 child list retains exact identity under updates, hides removed rows and follows theme" {
    defer theme.select(.sauber);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    defer cx.clearFocus();
    const button = try ui.widgets.Button(.{ .label = "子智能体" }).mount(scope, cx);
    try cx.root.?.appendChild(a, button);
    var selection: Selection = .{};
    const view = try View.mount(cx, scope, button, .{ .context = &selection, .select = Selection.select });
    try cx.root.?.appendChild(a, view.root);
    view.open.set(true);
    try view.update(&.{});
    try std.testing.expectEqualStrings("暂无子智能体", view.content.children.items[0].getText().?.content);
    const first: projection.Entry = .{ .agent = .generate(), .conversation = .generate(), .revision = 1, .name = "很长的日志核验名称 / 包含多字节 UTF-8 的独立任务", .summary = "核验明确授权范围", .status = "等待用户", .group = .attention, .running = false, .reusable = false };
    const second: projection.Entry = .{ .agent = .generate(), .conversation = .generate(), .revision = 1, .name = "运行任务", .status = "运行中", .group = .active, .running = true, .reusable = true };
    view.open.set(false);
    try view.update(&.{ first, second });
    try std.testing.expectEqualStrings("1", view.badge.getText().?.content);
    try std.testing.expect(view.badge.style.display == .flex);
    try view.updateWithCount(&.{ first, second }, 0);
    try std.testing.expect(view.badge.style.display == .none);
    try view.updateWithCount(&.{first}, 2);
    try std.testing.expectEqualStrings("2", view.badge.getText().?.content);
    view.open.set(true);
    try view.update(&.{ first, second });
    var key: [64]u8 = undefined;
    const row = find(view.content, try std.fmt.bufPrint(&key, "ai.child.{s}", .{std.fmt.bytesToHex(first.agent.bytes, .lower)})).?;
    for (0..8) |_| cx.layout();
    var second_key: [64]u8 = undefined;
    const second_row = find(view.content, try std.fmt.bufPrint(&second_key, "ai.child.{s}", .{std.fmt.bytesToHex(second.agent.bytes, .lower)})).?;
    const logo = find(row, "ai.child.logo").?.globalRect();
    const name = find(row, "ai.child.row.name").?.globalRect();
    const status = find(row, "ai.child.row.status").?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 32), logo.w, 0.1);
    try std.testing.expectApproxEqAbs(name.x, find(second_row, "ai.child.row.name").?.globalRect().x, 0.1);
    try std.testing.expectApproxEqAbs(name.x, find(cx.root.?, "ai.children.title").?.globalRect().x, 0.1);
    try std.testing.expectApproxEqAbs(status.x, find(second_row, "ai.child.row.status").?.globalRect().x, 0.1);
    try std.testing.expectApproxEqAbs(logo.y + logo.h / 2, status.y + status.h / 2, 0.1);
    try std.testing.expect(name.x + name.w <= status.x);
    try std.testing.expect(find(row, "ai.child.status.icon").?.getText() == null);
    const old_logo = find(row, "ai.child.logo").?;
    const old_icon = old_logo.children.items[0].getIcon().?.icon_id;
    var changed = first;
    changed.revision = 2;
    changed.group = .recent;
    changed.status = "已完成";
    changed.name = "改名后保留原标识";
    try view.update(&.{ second, changed });
    try std.testing.expect(row == find(view.content, key[0..41]).?);
    try std.testing.expect(old_logo == find(row, "ai.child.logo").?);
    try std.testing.expectEqual(old_icon, old_logo.children.items[0].getIcon().?.icon_id);
    for (0..8) |_| cx.layout();
    cx.setFocus(row);
    cx.handleKeyDown(.@"return", .{});
    try std.testing.expect(selection.agent != null and selection.agent.?.eql(first.agent));
    try std.testing.expectEqual(@as(u64, 2), selection.revision);
    view.open.set(true);
    try view.update(&.{second});
    try std.testing.expect(row.style.display == .none);
    theme.select(.light);
    try view.update(&.{second});
    try std.testing.expectEqualDeep(theme.current().overlay, view.chrome.getBackground());
    cx.clearFocus();
}

test "v0.4 shared assistant header and floating shadows retain the same geometry" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 720);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .row }, .{});
    const S = @import("ui/ai_assistant_styles.zig");
    const child_styles = @import("ui/ai_children_styles.zig");
    const Header = @import("ui/ai_assistant_header.zig");
    const parent_panel = try ui.boxStyled(cx, S.panel, .{});
    const child_panel = try ui.boxStyled(cx, S.panel, .{});
    try cx.root.?.appendChild(a, parent_panel);
    try cx.root.?.appendChild(a, child_panel);
    const parent = try Header.mount(cx, parent_panel, "Local Terminal");
    const child = try Header.mount(cx, child_panel, "日志核验");
    for (0..8) |_| cx.layout();
    try std.testing.expectApproxEqAbs(parent.bar.globalRect().y, child.bar.globalRect().y, 0.1);
    try std.testing.expectApproxEqAbs(parent.bar.globalRect().h, child.bar.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(parent.owner.globalRect().y, child.owner.globalRect().y, 0.1);
    try std.testing.expectApproxEqAbs(parent_panel.globalRect().h, child_panel.globalRect().h, 0.1);
    for ([_]ui.BoxStyle{ child_styles.popup(cx.tokens), child_styles.settings(cx.tokens), S.panel(cx.tokens) }) |style| {
        const panel = try ui.box(cx, style, .{});
        try cx.root.?.appendChild(a, panel);
        const shadows = panel.style.shadowSlice();
        try std.testing.expect(shadows.len != 0 and shadows[0].color.a > 0 and shadows[0].blur >= 16);
    }
}
