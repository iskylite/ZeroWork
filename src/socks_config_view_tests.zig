const std = @import("std");
const ui = @import("ui");
const m = @import("ui/socks_config_view.zig");
const C = struct { saved: usize = 0, tested: usize = 0, cancelled: usize = 0, exposure: bool = false };
test "forwarding switches follow palette and distinguish both positions" {
    const theme = @import("ui/app_theme.zig");
    defer theme.select(.sauber);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 700);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var c: C = .{};
    var publication: @import("ui/shell_styles.zig").ThemePublication = .{};
    const v = try m.View.mount(cx, scope, .{ .context = &c, .save = save, .test_cb = test_cb, .cancel = cancel, .confirm_exposure = exposure });
    if (!v.portaled) try root.appendChild(cx.allocator, v.root);
    for ([_][]const u8{ "forest", "plum", "sand" }) |id| {
        theme.selectTokens(@import("config/theme_registry.zig").builtinTokens(id));
        publication.publish(cx, theme.widgetTheme(theme.currentName()));
        try v.show(.{ .auto_start = false, .persist = true }, &.{});
        cx.layout();
        const off_track = v.auto.children.items[0];
        const on_track = v.persist.children.items[0];
        try std.testing.expectEqual(theme.switchTrackOff(), switchBackground(off_track));
        try std.testing.expectEqual(theme.current().action_accent, switchBackground(on_track));
        try std.testing.expectEqual(@as(f32, 2), off_track.children.items[0].style.ext.?.inset.left.px);
        try std.testing.expectEqual(@as(f32, 14), on_track.children.items[0].style.ext.?.inset.left.px);
        v.auto_value.set(true);
        v.persist_value.set(false);
        cx.layout();
        try std.testing.expectEqual(theme.current().action_accent, switchBackground(off_track));
        try std.testing.expectEqual(theme.switchTrackOff(), switchBackground(on_track));
    }
}
fn switchBackground(node: *ui.Node) ui.Color {
    if (node.frame_state.frame_local.runtime.transitions) |slots| if (slots.find(.background)) |slot| {
        if (slot.active) return slot.to_color;
    };
    return node.getBackground();
}
fn save(p: *anyopaque, d: m.Draft) void {
    _ = d;
    @as(*C, @ptrCast(@alignCast(p))).saved += 1;
}
fn test_cb(p: *anyopaque, d: m.Draft) void {
    _ = d;
    @as(*C, @ptrCast(@alignCast(p))).tested += 1;
}
fn cancel(p: *anyopaque) void {
    @as(*C, @ptrCast(@alignCast(p))).cancelled += 1;
}
fn exposure(p: *anyopaque, _: []const u8) bool {
    return @as(*C, @ptrCast(@alignCast(p))).exposure;
}
test "config modal mounts and checks exposure gate" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 420);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var c = C{};
    const v = try m.View.mount(cx, scope, .{ .context = @ptrCast(&c), .save = save, .test_cb = test_cb, .cancel = cancel, .confirm_exposure = exposure });
    if (!v.portaled) try root.appendChild(cx.allocator, v.root);
    try v.show(.{}, &.{});
    cx.layout();
    try std.testing.expect(v.root.style.display == .flex);
    v.bind_signal.set("0.0.0.0");
    v.draft.port = 1080;
    v.act(.save);
    try std.testing.expectEqual(@as(usize, 0), c.saved);
    c.exposure = true;
    v.act(.save);
    try std.testing.expectEqual(@as(usize, 1), c.saved);
    v.act(.cancel);
    try std.testing.expectEqual(@as(usize, 1), c.cancelled);
}

test "config owns routes and draft, validates inputs, resizes and cancels locally" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 420);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var c = C{};
    const v = try m.View.mount(cx, scope, .{ .context = @ptrCast(&c), .save = save, .test_cb = test_cb, .cancel = cancel, .confirm_exposure = exposure });
    if (!v.portaled) try root.appendChild(cx.allocator, v.root);
    var label = [_]u8{'A'};
    const routes = [_]m.Route{ .{ .label = "末端", .index = null }, .{ .label = &label, .index = 0 } };
    const original = m.Draft{ .port = 2000 };
    try v.show(original, &routes);
    label[0] = 'B';
    try std.testing.expectEqualStrings("A", v.routes[1].label);
    v.selectRoute(1);
    try std.testing.expectEqual(@as(?usize, 0), v.draft.exit);
    v.port_signal.set("bad");
    v.act(.save);
    try std.testing.expectEqual(@as(usize, 0), c.saved);
    try std.testing.expect(v.error_label.style.display == .flex);
    v.port_signal.set("2345");
    v.act(.test_proxy);
    try std.testing.expectEqual(@as(usize, 1), c.tested);
    for (0..4) |_| {
        cx.layout();
        _ = v.updateGeometry();
    }
    try std.testing.expect(v.card.globalRect().w <= 480.5);
    cx.setViewport(350, 200);
    for (0..4) |_| {
        cx.layout();
        _ = v.updateGeometry();
    }
    try std.testing.expect(v.card.globalRect().w <= 318.5);
    try std.testing.expect(v.scrolling.container.globalRect().h <= 130.5);
    v.act(.cancel);
    try std.testing.expectEqual(@as(u16, 2000), original.port);
    try std.testing.expectEqual(@as(usize, 0), c.saved);
}

test "configuration covers its owner and stays centered with fixed actions" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1440, 900);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var c = C{};
    const v = try m.View.mount(cx, scope, .{ .context = &c, .save = save, .test_cb = test_cb, .cancel = cancel, .confirm_exposure = exposure });
    if (!v.portaled) try root.appendChild(cx.allocator, v.root);
    v.setOwner("Owned multihop 3", 7);
    try v.show(.{}, &.{ .{ .label = "链路末端" }, .{ .label = "Owned multihop 1", .index = 0 } });
    for (0..8) |_| {
        cx.layout();
        _ = v.updateGeometry();
    }
    const overlay = v.root.globalRect();
    const card = v.card.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 1440), overlay.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 900), overlay.h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 480), card.w, 0.5);
    try std.testing.expect(card.h > 396 and card.h <= 650);
    try std.testing.expectApproxEqAbs(@as(f32, 720), card.x + card.w / 2, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 450), card.y + card.h / 2, 0.5);
    try std.testing.expect(v.footer.globalRect().y >= card.y);
    try std.testing.expect(v.footer.globalRect().y + v.footer.globalRect().h <= card.y + card.h);
    try std.testing.expectEqualStrings("归属 Owned multihop 3 · 会话 #7", v.owner_label.getText().?.content);
    cx.setViewport(860, 480);
    for (0..8) |_| {
        cx.layout();
        _ = v.updateGeometry();
    }
    const small = v.card.globalRect();
    try std.testing.expect(small.h <= 448.5);
    try std.testing.expectApproxEqAbs(@as(f32, 430), small.x + small.w / 2, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 240), small.y + small.h / 2, 0.5);
    try std.testing.expect(small.y >= 0 and small.y + small.h <= 480.5);
}

test "configuration changes global palette without replacing inputs or selected exit" {
    const theme = @import("ui/app_theme.zig");
    const previous = theme.currentName();
    defer theme.select(previous);
    theme.select(.dark);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setTheme(theme.widgetTheme(.dark));
    cx.setViewport(1440, 900);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var c = C{};
    const v = try m.View.mount(cx, scope, .{ .context = &c, .save = save, .test_cb = test_cb, .cancel = cancel, .confirm_exposure = exposure });
    if (!v.portaled) try root.appendChild(cx.allocator, v.root);
    try v.show(.{ .port = 3456 }, &.{ .{ .label = "末端" }, .{ .label = "首跳", .index = 0 }, .{ .label = "中间跳", .index = 1 } });
    const original_input = v.input_parts[0].input_container;
    v.port_signal.set("4567");
    v.selectRoute(2);
    v.setSuccess("真实测试成功");
    inline for (.{ .light, .sauber, .dark }) |name| {
        theme.select(name);
        cx.setTheme(theme.widgetTheme(name));
        for (0..8) |_| {
            cx.layout();
            _ = v.updateGeometry();
        }
        v.picker.open.?.set(true);
        for (0..4) |_| cx.layout();
        const first = findId(v.picker.panel, "socks.config.route.1").?;
        _ = first.behavior.events.on_event.?(.{ .click = .{ .x = 0, .y = 0 } }, first.behavior.events.event_context);
        try std.testing.expectEqual(@as(?usize, 0), v.draft.exit);
        v.picker.open.?.set(true);
        for (0..4) |_| cx.layout();
        const second = findId(v.picker.panel, "socks.config.route.2").?;
        _ = second.behavior.events.on_event.?(.{ .click = .{ .x = 0, .y = 0 } }, second.behavior.events.event_context);
        try std.testing.expectEqual(original_input, v.input_parts[0].input_container);
        try std.testing.expectEqualStrings("4567", v.port_signal.get());
        try std.testing.expectEqual(@as(?usize, 1), v.draft.exit);
        try std.testing.expectEqualStrings("2", v.route_value.get().?);
        try std.testing.expect(ui.Color.eql(theme.current().fg_1, ui.widgets.select.stateOf(v.picker).colors.text_primary));
        try std.testing.expect(ui.Color.eql(theme.current().overlay, v.card.getBackground()));
        _ = cx.render();
        try std.testing.expect(cx.isFocused(original_input));
        try std.testing.expectEqual(cx.tokens.tokens.color.bg_active, original_input.getBackground());
        try std.testing.expect(original_input.style.outline() == null);
        cx.clearFocus();
        _ = cx.render();
        try std.testing.expectEqual(theme.current().well, original_input.getBackground());
        cx.setFocus(original_input);
        _ = cx.render();
        try std.testing.expectEqual(cx.tokens.tokens.color.bg_active, original_input.getBackground());
        try std.testing.expect(ui.Color.eql(theme.current().fg_1, v.title.getText().?.color));
        try std.testing.expect(ui.Color.eql(theme.current().ok_ink, v.error_label.getText().?.color));
    }
    v.act(.save);
    try std.testing.expectEqual(@as(usize, 1), c.saved);
    try std.testing.expectEqual(@as(?usize, 1), v.draft.exit);
    try std.testing.expectEqual(@as(u16, 4567), v.draft.port);
}

fn findId(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (findId(child, id)) |found| return found;
    return null;
}

test "existing wizard protocol Select uses Light and Sauber tokens and still selects SFTP" {
    const theme = @import("ui/app_theme.zig");
    const Wizard = @import("plugins/remote/editor.zig").RemoteEditor;
    const previous = theme.currentName();
    defer theme.select(previous);
    inline for (.{ .light, .sauber }) |name| {
        theme.select(name);
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setTheme(theme.widgetTheme(name));
        cx.setViewport(1440, 900);
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        defer scope.dispose();
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        var wizard: Wizard = .{};
        try cx.root.?.appendChild(cx.allocator, try wizard.mount(cx, scope));
        wizard.show();
        for (0..8) |_| {
            cx.layout();
            _ = wizard.updateViewport();
        }
        const protocol = wizard.selects.items[0];
        try std.testing.expectEqualStrings("wizard.protocol", protocol.trigger.meta.ownership.meta.test_id.?);
        try std.testing.expect(ui.Color.eql(theme.current().fg_1, ui.widgets.select.stateOf(protocol).colors.text_primary));
        try std.testing.expect(ui.Color.eql(theme.current().accent, ui.widgets.select.stateOf(protocol).colors.primary));
        protocol.open.?.set(true);
        for (0..4) |_| cx.layout();
        const option = findId(protocol.panel, "wizard.protocol.sftp").?;
        const event = option.behavior.events.on_event.?;
        _ = event(.{ .click = .{ .x = 0, .y = 0 } }, option.behavior.events.event_context);
        for (0..4) |_| cx.layout();
        try std.testing.expectEqualStrings("sftp", wizard.sig_protocol.?.get().?);
        try std.testing.expectEqual(@import("plugins/remote/editor.zig").Protocol.sftp, wizard.protocol);
        try std.testing.expect(!protocol.open.?.get());
    }
}

fn hasOpaqueLeaf(node: *ui.Node, color: ui.Color) bool {
    if (node.children.items.len == 0 and ui.Color.eql(node.getBackground(), color)) return true;
    for (node.children.items) |child| if (hasOpaqueLeaf(child, color)) return true;
    return false;
}
fn hasTexture(node: *ui.Node, id: u32) bool {
    if (node.getImage()) |image| if (image.texture_id == id) return true;
    for (node.children.items) |child| if (hasTexture(child, id)) return true;
    return false;
}

test "configuration Select reveals one global material through options and theme updates" {
    const theme = @import("ui/app_theme.zig");
    const background = @import("ui/background_layers.zig");
    const previous = theme.currentName();
    const was_material = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(was_material);
    }
    theme.select(.light);
    _ = theme.setMaterialVisible(true);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setTheme(theme.widgetTheme(.light));
    cx.setViewport(1440, 900);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    const material = try background.View.mount(cx, scope);
    try root.appendChild(cx.allocator, material.root);
    var c = C{};
    const v = try m.View.mount(cx, scope, .{ .context = &c, .save = save, .test_cb = test_cb, .cancel = cancel, .confirm_exposure = exposure });
    if (!v.portaled) try root.appendChild(cx.allocator, v.root);
    try v.bindMaterial(material);
    try material.update(.{ .id = 73, .width = 320, .height = 180 }, .{ .background = .{ .enabled = true, .path = "/owned-headless-fixture", .transparency = 100 }, .blur_px = 4 }, 1440, 900);
    inline for (.{ .light, .sauber, .dark }) |name| {
        theme.select(name);
        cx.setTheme(theme.widgetTheme(name));
        try v.show(.{}, &.{ .{ .label = "末端" }, .{ .label = "首跳", .index = 0 } });
        for (0..8) |_| {
            cx.layout();
            _ = v.updateGeometry();
        }
        v.picker.open.?.set(true);
        for (0..8) |_| {
            cx.layout();
            _ = cx.render();
        }
        try material.update(.{ .id = 73, .width = 320, .height = 180 }, .{ .background = .{ .enabled = true, .path = "/owned-headless-fixture", .transparency = 100 }, .blur_px = 4 }, 1440, 900);
        cx.layout();
        try std.testing.expectEqual(@as(u8, 0), v.picker.panel.getBackground().a);
        try std.testing.expect(findId(v.picker.chrome, "appearance.surface") == null);
        try std.testing.expect(hasTexture(material.root, 73));
        try std.testing.expect(!hasTexture(v.picker.chrome, 73));
        // Updating Select options keeps the single global background untouched.
        try v.show(.{}, &.{ .{ .label = "新末端" }, .{ .label = "新首跳", .index = 0 } });
        for (0..4) |_| cx.layout();
        try std.testing.expect(findId(v.picker.chrome, "appearance.surface") == null);
        try std.testing.expectEqual(@as(u8, 0), v.picker.panel.getBackground().a);
        try std.testing.expect(v.card.globalRect().h > 396 and v.card.globalRect().h <= 650);
    }
}

test "forward modes validate fixed targets and keep session-only settings" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var c = C{};
    const v = try m.View.mount(cx, scope, .{ .context = &c, .save = save, .test_cb = test_cb, .cancel = cancel, .confirm_exposure = exposure });
    if (!v.portaled) try root.appendChild(cx.allocator, v.root);
    try v.show(.{}, &.{});
    v.act(.mode_local);
    for (v.mode_highlights, 0..) |highlight, i| try std.testing.expectEqual(i == 1, highlight.style.display == .flex);
    try std.testing.expect(v.target_group.style.display == .flex);
    try std.testing.expect(v.persist_row.style.display == .none);
    v.target_host_signal.set("database.internal");
    v.target_port_signal.set("0");
    v.act(.save);
    try std.testing.expectEqual(@as(usize, 0), c.saved);
    v.target_port_signal.set("5432");
    v.act(.save);
    try std.testing.expectEqual(@as(usize, 1), c.saved);
    try std.testing.expect(!v.draft.persist and !v.draft.auto_start);
    v.act(.mode_remote);
    for (v.mode_highlights, 0..) |highlight, i| try std.testing.expectEqual(i == 2, highlight.style.display == .flex);
    v.act(.save);
    try std.testing.expectEqual(@as(usize, 1), c.saved);
    try std.testing.expect(std.mem.indexOf(u8, v.error_label.getText().?.content, "IPv4") != null);
    v.target_host_signal.set("::1");
    v.act(.save);
    try std.testing.expectEqual(@as(usize, 2), c.saved);
    v.act(.mode_socks5);
    for (v.mode_highlights, 0..) |highlight, i| try std.testing.expectEqual(i == 0, highlight.style.display == .flex);
    try std.testing.expect(v.target_group.style.display == .none);
    try std.testing.expect(v.persist_row.style.display == .flex);
}
