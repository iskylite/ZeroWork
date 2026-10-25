//! Real production Cx/render regression: palette/material publication retains
//! the original SOCKS state, text, trigger, nodes and geometry.
const std = @import("std");
const ui = @import("ui");
const socks = @import("ui/socks_info_view.zig");
const theme = @import("ui/app_theme.zig");
const layers = @import("ui/background_layers.zig");
const assets = @import("config/background_asset.zig");

fn frame(cx: *ui.Cx) []const ui.DisplayItem {
    // Actual Buttons animate role changes for 150ms; compare their settled paint.
    for (0..12) |_| {
        cx.frame_count += 1;
        cx.frame_time_ms += 16;
        _ = cx.render();
    }
    return cx.render();
}

test "socks global material paints retained foreground from every theme with local backdrop blur and no state changes" {
    const saved_material = theme.materialParameters();
    defer _ = theme.setMaterialParameters(saved_material.transparency, saved_material.blur);
    _ = theme.setMaterialParameters(50, 12);
    const previous = theme.currentName();
    const visible = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(visible);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(false);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 720);
    // Widget transitions read the renderer's shared clock at mount. Bind this
    // fixture's clock before creating controls so earlier Cx tests cannot leave
    // their animation starts in this fixture's future.
    try cx.setTestFrameStep(16);
    cx.bindFrameClock();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const source = try layers.View.mount(cx, scope);
    try cx.root.?.appendChild(cx.allocator, source.root);
    const Receipt = struct {
        actions: usize = 0,
        fn action(raw: *anyopaque, _: socks.Action) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.actions += 1;
        }
    };
    var receipt: Receipt = .{};
    const view = try socks.mount(cx, scope, .{ .context = &receipt, .action = Receipt.action });
    if (!view.portaled) try cx.root.?.appendChild(cx.allocator, view.wrapper);
    try source.isolate(view.scope, view.root);
    const trigger = try ui.box(cx, .{ .position = .absolute, .width = .{ .px = 80 }, .height = .{ .px = 24 }, .inset = .{ .right = .{ .px = 20 }, .bottom = .{ .px = 12 } } }, .{});
    try cx.root.?.appendChild(cx.allocator, trigger);
    try view.update(.{ .state = .running, .host = "original-host", .exit = "original-target", .route = "original-route", .port = 1081, .connections = 2, .uploaded = 2048, .test_result = "original result" });
    view.showNode(trigger);
    _ = frame(cx);
    const original_rect = view.root.globalRect();
    const original_pointer = view.pointer.globalRect();
    const original_id = view.root.id;
    const body_id = view.body.content.id;
    const address_id = view.address.id;
    var materials: assets.Materials = .{ .background = .{ .enabled = false, .path = "/fixture", .fit = .fit, .transparency = 50 }, .blur_px = 12 };
    for (std.enums.values(theme.Name)) |name| for ([_]bool{ false, true }) |image_visible| {
        theme.select(name);
        _ = theme.setMaterialVisible(image_visible);
        materials.background.enabled = image_visible;
        try source.update(if (image_visible) .{ .id = 777, .width = 640, .height = 256 } else null, materials, 1280, 720);
        // The production after-layout hook observes the global role changes.
        // No test-side retheme call or view rebuild is needed.
        const items = frame(cx);
        const c = theme.current();
        try std.testing.expectEqual(c.overlay, view.root.getBackground());
        try std.testing.expectEqual(ui.Color.TRANSPARENT, view.pointer.getBackground());
        try std.testing.expectEqual(c.border, view.root.style.border.color);
        try std.testing.expectEqual(c.surface_2, view.copy_button.getBackground());
        try std.testing.expectEqual(c.accent, view.config_button.getBackground());
        try std.testing.expectEqual(c.fg_1, view.address.getText().?.color);
        try std.testing.expectEqual(c.fg_3, view.route.getText().?.color);
        try std.testing.expectEqual(c.ok_ink, view.status.getText().?.color);
        try std.testing.expectEqual(c.fg_2, view.control_text.getText().?.color);
        try std.testing.expectEqual(c.fg_2, view.message.getText().?.color);
        try std.testing.expectEqual(@as(f32, 12), view.root.style.backdrop_blur());
        try std.testing.expectEqual(socks.State.running, view.state);
        try std.testing.expectEqualStrings("original-target", view.exit.getText().?.content);
        try std.testing.expectEqualStrings("original-route", view.route.getText().?.content);
        try std.testing.expectEqualStrings("127.0.0.1:1081", view.address.getText().?.content);
        try std.testing.expectEqual(original_id, view.root.id);
        try std.testing.expectEqual(body_id, view.body.content.id);
        try std.testing.expectEqual(address_id, view.address.id);
        try std.testing.expectEqual(trigger, view.anchor_node.?);
        inline for (.{ "x", "y", "w", "h" }) |axis| {
            try std.testing.expectApproxEqAbs(@field(original_rect, axis), @field(view.root.globalRect(), axis), 0.01);
            try std.testing.expectApproxEqAbs(@field(original_pointer, axis), @field(view.pointer.globalRect(), axis), 0.01);
        }
        var painted_original = false;
        for (items) |item| switch (item) {
            .text_run => |run| if (std.mem.eql(u8, run.content, "original-target")) {
                try std.testing.expectEqual(c.fg_2, run.color);
                painted_original = true;
            },
            else => {},
        };
        try std.testing.expect(painted_original);
        try std.testing.expectEqual(@as(usize, 0), receipt.actions);
    };
    // State-specific colors keep their semantics after material/role changes.
    for (std.enums.values(socks.State)) |state| {
        try view.update(.{ .state = state, .error_text = "original error" });
        _ = frame(cx);
        const c = theme.current();
        const expected = switch (state) {
            .running => c.ok_ink,
            .connecting, .paused => c.warn_ink,
            .failed => c.danger_ink,
            .off => c.fg_3,
        };
        try std.testing.expectEqual(expected, view.status.getText().?.color);
        try std.testing.expectEqual(c.danger_ink, view.message.getText().?.color);
        try std.testing.expectEqual(state, view.state);
        try std.testing.expectEqual(@as(usize, 0), receipt.actions);
    }
    view.hide();
    _ = frame(cx);
    try std.testing.expectEqual(.none, view.root.style.display);
    theme.select(.light);
    _ = theme.setMaterialVisible(false);
    materials.background.enabled = false;
    try source.update(null, materials, 1280, 720);
    _ = frame(cx);
    try std.testing.expectEqual(.none, view.root.style.display);
    try std.testing.expectEqual(theme.current().overlay, view.root.getBackground());
    try std.testing.expectEqual(@as(usize, 0), receipt.actions);
}
