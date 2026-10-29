const ui = @import("ui");
const V = @import("ui/ai_remote_picker.zig");

test "AI remote filename button stays inside its bounded table cell" {
    const std = @import("std");
    const Probe = struct {
        clicks: usize = 0,
        fn click(self: *@This()) void {
            self.clicks += 1;
        }
    };
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const cell = try ui.box(cx, .{ .width = .{ .px = 180 }, .height = .{ .px = 43 }, .direction = .row, .min_width = 0 }, .{});
    try cx.root.?.appendChild(allocator, cell);
    var probe: Probe = .{};
    const name = "very-long-remote-filename-that-must-not-paint-over-the-size-or-modified-time-column.txt";
    const filename = try V.filenameButton(scope, cx, name, cx.on(Probe, &probe, Probe.click));
    const button_node = filename.button;
    try cell.appendChild(allocator, button_node);
    cx.layout();
    const rect = button_node.globalRect();
    try std.testing.expectEqual(@as(f32, 180), rect.w);
    try std.testing.expectEqual(@as(f32, 32), rect.h);
    const label = filename.label;
    try std.testing.expect(label.getText().?.text_overflow == .ellipsis);
    try std.testing.expect(label.globalRect().x + label.globalRect().w <= rect.x + rect.w);
    try std.testing.expectEqualStrings(name, button_node.behavior.interaction.a11y.?.label.?);
    cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    try std.testing.expectEqual(@as(usize, 1), probe.clicks);
}

test "AI remote picker leaves a reused earlier authentication modal accessible" {
    const std = @import("std");
    const Shared = @import("ui/challenge_window_host.zig").Services;
    const files = @import("host/file_binding_host.zig");
    const attachments = @import("ai/local_text_attachments.zig");
    const scope_mod = @import("ai/tool_scope.zig");
    const Callbacks = struct {
        fn ensure(_: *anyopaque, _: V.Source) !files.Bindings {
            return error.UnexpectedFileConnection;
        }
        fn live(_: *anyopaque, _: scope_mod.Owner) ?scope_mod.Scope {
            return null;
        }
        fn stage(_: *anyopaque, _: scope_mod.Owner, _: *attachments.ContentRef) !void {
            return error.UnexpectedAttachment;
        }
    };
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1100, 720);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    // The window creates its shared authentication presenter before the AI
    // picker. Its later challenge reuses that original portal node.
    const shared = try Shared.mount(cx, scope);
    var unused_host: files.FileBindingHost = undefined;
    var context: u8 = 0;
    const picker = try V.View.mount(cx, scope, &unused_host, .{ .context = &context, .ensure = Callbacks.ensure, .live = Callbacks.live, .stage = Callbacks.stage });
    defer picker.release() catch unreachable;
    try cx.root.?.appendChild(allocator, picker.root);
    try picker.open(.{ .session = 1 }, &.{});
    cx.layout();
    _ = cx.render();

    const owner: @import("host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(1), .generation = 1 };
    try shared.host.offer(owner, 1, 1, .trust_material, .{ .title = "核对主机密钥", .choices = &.{ .{ .value = "trust_once", .label = "仅本次信任" }, .{ .value = "trust_save", .label = "保存并继续" } } }, std.math.maxInt(u64));
    try shared.view.update(owner);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.overlay_stack.topmost().?.content_node == shared.view.modal.dialog);
    try std.testing.expect(cx.focus_manager.activeScope() == shared.view.modal.overlay);
    const action_id = ui.a11y.AXId.fromRaw(shared.view.trust_actions[0].element_id_raw);
    const action = cx.accessibility_tree.get(action_id).?;
    try std.testing.expect(!action.state.hidden);
    try std.testing.expect(!action.state.disabled);

    // Dismissing this independent challenge restores the still-open picker.
    _ = try shared.host.withdraw(owner, 1, 1);
    try shared.view.update(owner);
    for (0..20) |_| {
        var unused: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&unused, 0, 16);
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expect(picker.open_state);
    try std.testing.expect(cx.focus_manager.activeScope() != shared.view.modal.overlay);
    const close = struct {
        fn find(node: *ui.Node) ?*ui.Node {
            if (node.meta.ownership.meta.test_id) |id| if (std.mem.eql(u8, id, "ai.remote.close")) return node;
            for (node.children.items) |child| if (find(child)) |found| return found;
            return null;
        }
    }.find(cx.root.?).?;
    const close_action = cx.accessibility_tree.get(ui.a11y.AXId.fromRaw(close.element_id_raw)).?;
    try std.testing.expect(!close_action.state.hidden);
    try std.testing.expect(!close_action.state.disabled);
}

test {
    _ = @import("ui/ai_remote_reference.zig");
}
