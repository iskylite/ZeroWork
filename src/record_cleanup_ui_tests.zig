const std = @import("std");
const ui = @import("ui");
const theme = @import("ui/app_theme.zig");
const cleanup_view = @import("ui/record_cleanup_view.zig");
const publication = @import("ui/shell_styles.zig").ThemePublication;
test {
    _ = @import("record_cleanup_tests.zig");
}

const Receipt = struct {
    calls: usize = 0,
    action: ?cleanup_view.Action = null,
    fn handle(raw: *anyopaque, action: cleanup_view.Action) void {
        const self: *Receipt = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.action = action;
    }
};
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    publish: *publication,
    fn init() !Fixture {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(1000, 700);
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        errdefer scope.dispose();
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        const publish = try cx.bindState(publication, .{});
        publish.publish(cx, theme.widgetTheme(theme.currentName()));
        return .{ .cx = cx, .scope = scope, .publish = publish };
    }
    fn deinit(self: Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
    }
    fn frame(self: Fixture) void {
        // Allow the existing Button/Modal paint transitions to settle.
        for (0..24) |_| {
            self.cx.frame_count += 1;
            self.cx.frame_time_ms += 16;
            _ = self.cx.render();
        }
    }
    fn apply(self: Fixture, name: theme.Name, material: bool) void {
        theme.select(name);
        _ = theme.setMaterialVisible(material);
        self.publish.publish(self.cx, theme.widgetTheme(name));
        self.frame();
    }
    fn click(self: Fixture, node: *ui.Node) void {
        const r = node.globalRect();
        self.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
        self.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
        self.frame();
    }
};

test "record cleanup modal has exact Bridge dimensions default cancel and Escape never confirms" {
    const previous = theme.currentName();
    const material = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(material);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(false);
    const f = try Fixture.init();
    defer f.deinit();
    var receipt: Receipt = .{};
    const outside = try ui.widgets.Button(.{ .label = "清理记录" }).mount(f.scope, f.cx);
    try f.cx.root.?.appendChild(f.cx.allocator, outside);
    const view = try cleanup_view.View.mount(f.cx, f.scope, .{ .context = &receipt, .action = Receipt.handle });
    f.frame();
    f.cx.setFocus(outside);
    try view.showConfirmation();
    f.frame();
    try std.testing.expectEqual(@as(f32, 440), view.dialog.globalRect().w);
    try std.testing.expectEqual(@as(f32, 146), view.dialog.globalRect().h);
    try std.testing.expectEqual(@as(f32, 96), view.cancel.globalRect().w);
    try std.testing.expectEqual(@as(f32, 34), view.cancel.globalRect().h);
    try std.testing.expectEqual(@as(f32, 22), view.close.globalRect().w);
    try std.testing.expectApproxEqAbs(@as(f32, 100), view.cancel.globalRect().y - view.dialog.globalRect().y, 0.1);
    try std.testing.expect(f.cx.focus_manager.getFocused() == view.cancel);
    try std.testing.expectEqualStrings("", view.receipt.getText().?.content);
    try std.testing.expectEqual(@as(usize, 0), receipt.calls);
    f.cx.handleKeyDown(.escape, .{});
    f.frame();
    try std.testing.expect(!view.open.peek());
    try std.testing.expectEqual(@as(usize, 1), receipt.calls);
    try std.testing.expectEqual(cleanup_view.Action.dismiss, receipt.action.?);
    try std.testing.expect(f.cx.focus_manager.getFocused() == outside);
}

test "record cleanup modal routes confirm retry and completion through existing Button gestures" {
    const f = try Fixture.init();
    defer f.deinit();
    var receipt: Receipt = .{};
    const view = try cleanup_view.View.mount(f.cx, f.scope, .{ .context = &receipt, .action = Receipt.handle });
    try view.showConfirmation();
    f.frame();
    f.click(view.primary);
    try std.testing.expectEqual(cleanup_view.Action.confirm, receipt.action.?);
    try view.update(.{ .total = 2, .deleted = 1, .failed = 1 }, error.RecordBusy, false);
    f.frame();
    try std.testing.expectEqualStrings("已清理 1 项 · 失败 1 项", view.receipt.getText().?.content);
    f.click(view.primary);
    try std.testing.expectEqual(cleanup_view.Action.retry, receipt.action.?);
    try view.update(.{ .total = 2, .deleted = 2 }, null, false);
    f.frame();
    f.click(view.primary);
    try std.testing.expectEqual(cleanup_view.Action.dismiss, receipt.action.?);
    try std.testing.expect(!view.open.peek());
}

test "record cleanup modal retained theme and background publication preserves counts owner callback and focus" {
    const previous = theme.currentName();
    const material = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(material);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(false);
    const f = try Fixture.init();
    defer f.deinit();
    var receipt: Receipt = .{};
    const view = try cleanup_view.View.mount(f.cx, f.scope, .{ .context = &receipt, .action = Receipt.handle });
    try view.showConfirmation();
    f.frame();
    try view.update(.{ .total = 3, .deleted = 2, .failed = 1 }, error.AccessDenied, true);
    f.frame();
    const focus = f.cx.focus_manager.getFocused();
    const id = view.dialog.id;
    f.apply(.light, false);
    try std.testing.expectEqual(theme.current().overlay, view.dialog.getBackground());
    // Cancel retains keyboard focus, whose focus-visible paint overrides its base background.
    try std.testing.expectEqual(theme.current().surface_2, view.cancel_style.peek().background.?);
    try std.testing.expectEqual(theme.current().fg_1, view.detail.getText().?.color);
    f.apply(.sauber, true);
    try std.testing.expectEqual(theme.current().overlay, view.dialog.getBackground());
    try std.testing.expectEqual(theme.current().fg_2, view.receipt.getText().?.color);
    try std.testing.expectEqualStrings("已清理 2 项 · 失败 1 项", view.receipt.getText().?.content);
    try std.testing.expect(std.mem.startsWith(u8, view.headline.getText().?.content, "文件缺失"));
    try std.testing.expectEqual(id, view.dialog.id);
    try std.testing.expectEqual(focus, f.cx.focus_manager.getFocused());
    try std.testing.expectEqual(@as(usize, 0), receipt.calls);
    view.hide();
    f.frame();
    f.apply(.dark, false);
    try view.showConfirmation();
    f.frame();
    try std.testing.expectEqual(theme.current().overlay, view.dialog.getBackground());
    // Imported palettes share the same global slots, including danger ink.
    var custom = theme.colors(.dark);
    custom.overlay = ui.Color.rgb(34, 48, 60);
    custom.danger = ui.Color.rgb(180, 80, 30);
    custom.danger_ink = ui.Color.rgb(248, 180, 70);
    var tokens: @import("config/theme_registry.zig").UiTokens = undefined;
    inline for (@typeInfo(theme.Colors).@"struct".field_names) |field| {
        const color = @field(custom, field);
        @field(tokens, field) = (@as(u32, color.r) << 24) | (@as(u32, color.g) << 16) | (@as(u32, color.b) << 8) | @as(u32, color.a);
    }
    theme.selectTokens(tokens);
    f.publish.publish(f.cx, theme.widgetTheme(.dark));
    f.frame();
    // Imported RGB values share the same material alpha as built-in palettes.
    try std.testing.expectEqual(custom.overlay.withAlpha(theme.materialAlpha("overlay")), view.dialog.getBackground());
    try std.testing.expectEqual(custom.action_danger, backgroundTarget(view.primary));
    try std.testing.expectEqual(custom.danger_ink, view.headline.getText().?.color);
}

test "record cleanup failure headline and receipt stay inside the content stack" {
    const f = try Fixture.init();
    defer f.deinit();
    var receipt: Receipt = .{};
    const view = try cleanup_view.View.mount(f.cx, f.scope, .{ .context = &receipt, .action = Receipt.handle });
    try view.showConfirmation();
    try view.update(.{ .total = 3, .deleted = 2, .failed = 1 }, error.AccessDenied, true);
    f.frame();
    const stack = view.content_stack.globalRect();
    const receipt_rect = view.receipt.globalRect();
    try std.testing.expect(receipt_rect.y + receipt_rect.h <= stack.y + stack.h + 0.1);
    const headline_layout = view.headline.layoutTextLayout().?;
    try std.testing.expect(headline_layout.total_height <= view.headline.globalRect().h + 0.1);
    const actions = view.primary.globalRect();
    try std.testing.expect(receipt_rect.y + receipt_rect.h <= actions.y);
}

fn backgroundTarget(node: *ui.Node) ui.Color {
    if (node.frame_state.frame_local.runtime.transitions) |transitions| {
        if (transitions.find(.background)) |slot| if (slot.active) return slot.to_color;
    }
    return node.getBackground();
}
