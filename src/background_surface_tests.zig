//! No-window production Cx/render checks for floating global material surfaces.
const std = @import("std");
const ui = @import("ui");
const layers = @import("ui/background_layers.zig");
const assets = @import("config/background_asset.zig");
const theme = @import("ui/app_theme.zig");
const shell = @import("ui/shell_styles.zig");

test "terminal fixed grid glyph replacement preserves geometry and interaction indexes" {
    const fixture = @import("ui/terminal_surface_tests.zig");
    const View = @import("ui/terminal_view.zig").TerminalViewNode;
    var transport: fixture.FakeTransport = undefined;
    try transport.init(4, 16);
    defer transport.deinit();
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 400);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    try view.bindTerminalService(transport.service());
    try transport.controller.feedOutput(fixture.owner, 1, "0000", 100);
    for (0..4) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = try view.refreshTerminalService(fixture.owner, false);
        _ = cx.render();
    }
    const surface = view.terminal_surface.?;
    const glyph = surface.rows.items[0].glyphs.items[0].node;
    const previous = glyph.globalRect();
    try transport.controller.feedOutput(fixture.owner, 2, "\r1111", 200);
    _ = try view.refreshTerminalService(fixture.owner, false);
    try std.testing.expect(surface.rows.items[0].glyphs.items[0].node == glyph);
    try std.testing.expectEqualStrings("1111", glyph.getText().?.content);
    try std.testing.expect(!glyph.frame_state.state_bits.dirty.core.layout);
    try std.testing.expect(!glyph.frame_state.state_bits.dirty.hit.geometry);
    try std.testing.expect(glyph.frame_state.state_bits.dirty.core.render);
    try expectRect(previous, glyph.globalRect());
}

test "retained window panel leaves closed tree and reopens with the same state and order" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 400);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const panel = try ui.box(cx, .{ .position = .absolute, .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    try cx.root.?.appendChild(cx.allocator, panel);
    const text = try ui.text(cx, "retained draft", .{});
    try panel.appendChild(cx.allocator, text);
    const sibling = try ui.box(cx, .{}, .{});
    try cx.root.?.appendChild(cx.allocator, sibling);
    const original_id = panel.id;
    panel.setDisplay(.none);
    _ = try @import("ui/retained_panel.zig").Panel.mount(cx, scope, cx.root.?, panel);
    try std.testing.expect(panel.parent == null);
    try std.testing.expectEqual(@as(usize, 1), cx.root.?.children.items.len);
    try text.setTextContent(cx.allocator, "changed while closed");
    panel.setDisplay(.flex);
    cx.requestRedraw();
    for (0..3) |_| {
        cx.advanceFrameClock();
        _ = cx.render();
    }
    try std.testing.expect(panel.parent == cx.root);
    try std.testing.expect(cx.root.?.children.items[0] == panel);
    try std.testing.expectEqual(original_id, panel.id);
    try std.testing.expectEqualStrings("changed while closed", text.getText().?.content);
    panel.setDisplay(.none);
    cx.requestRedraw();
    for (0..3) |_| {
        cx.advanceFrameClock();
        _ = cx.render();
    }
    try std.testing.expect(panel.parent == null);
    // Scope disposal frees this now-detached branch; testing allocator checks
    // its retained text and descendants along with the panel ownership cell.
}

test "retained window panel disposes while attached without owning the root twice" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const panel = try ui.box(cx, .{}, .{});
    try cx.root.?.appendChild(cx.allocator, panel);
    _ = try @import("ui/retained_panel.zig").Panel.mount(cx, scope, cx.root.?, panel);
    try std.testing.expect(panel.parent == cx.root);
}

test "retained window panel cleanup tolerates a parent-owned branch already freed" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{}, .{});
    const panel = try ui.box(cx, .{}, .{});
    try cx.root.?.appendChild(cx.allocator, panel);
    _ = try @import("ui/retained_panel.zig").Panel.mount(cx, scope, cx.root.?, panel);
    cx.detachChild(cx.root.?, panel);
    cx.destroyDetached(panel);
    // The retained owner holds only a tracked identity; cleanup must not read
    // the old allocation or free it twice on a failed window construction path.
}

test "retained window panel revokes capture focus and old input handles across reopening" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 400);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const panel = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    const editor = try ui.widgets.Input(.{}).mountResult(scope, cx);
    try panel.appendChild(cx.allocator, editor.node);
    try cx.root.?.appendChild(cx.allocator, panel);
    _ = try @import("ui/retained_panel.zig").Panel.mount(cx, scope, cx.root.?, panel);
    cx.advanceFrameClock();
    _ = cx.render();
    const previous = cx.node_registry.handleFor(editor.input_container);
    cx.setFocus(editor.input_container);
    cx.setPointerCapture(editor.input_container);
    try std.testing.expect(cx.dispatcher.hasPointerCapture());
    panel.setDisplay(.none);
    cx.advanceFrameClock();
    cx.requestRedraw();
    _ = cx.render();
    try std.testing.expect(panel.parent == null);
    try std.testing.expect(cx.focus_manager.getFocused() == null);
    try std.testing.expect(!cx.dispatcher.hasPointerCapture());
    try std.testing.expect(cx.node_registry.resolve(previous, null) == null);
    panel.setDisplay(.flex);
    cx.advanceFrameClock();
    cx.requestRedraw();
    _ = cx.render();
    try std.testing.expect(panel.parent == cx.root);
    try std.testing.expect(cx.node_registry.resolve(previous, null) == null);
    try std.testing.expect(cx.node_registry.resolve(cx.node_registry.handleFor(editor.input_container), null) == editor.input_container);
}

test "retained window panel accepts the first letter after its opening frame" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 400);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const panel = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    const editor = try ui.widgets.Input(.{ .placeholder = "retained editor" }).mountResult(scope, cx);
    try panel.appendChild(cx.allocator, editor.node);
    try cx.root.?.appendChild(cx.allocator, panel);
    panel.setDisplay(.none);
    const retained = try @import("ui/retained_panel.zig").Panel.mount(cx, scope, cx.root.?, panel);
    retained.focusWhenAttached(editor.input_container);
    panel.setDisplay(.flex);
    cx.requestRedraw();
    // Native input resumes after this frame. Waiting additional frames hides
    // the interval where a visible panel still routes text to the old owner.
    cx.advanceFrameClock();
    _ = cx.render();
    try std.testing.expect(cx.focus_manager.getFocused() == editor.input_container);
    cx.handleKeyDown(.a, .{});
    cx.handleTextInput("a");
    try std.testing.expectEqualStrings("a", editor.state.getText());
}

test "retained window panel does not steal focus after a newer outside focus request" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 400);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const outside = try ui.widgets.Input(.{}).mountResult(scope, cx);
    try cx.root.?.appendChild(cx.allocator, outside.node);
    const panel = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    const editor = try ui.widgets.Input(.{}).mountResult(scope, cx);
    try panel.appendChild(cx.allocator, editor.node);
    try cx.root.?.appendChild(cx.allocator, panel);
    panel.setDisplay(.none);
    const retained = try @import("ui/retained_panel.zig").Panel.mount(cx, scope, cx.root.?, panel);
    for (0..2) |_| {
        cx.advanceFrameClock();
        _ = cx.render();
    }
    retained.focusWhenAttached(editor.input_container);
    cx.setFocus(outside.input_container);
    panel.setDisplay(.flex);
    cx.requestRedraw();
    for (0..5) |_| {
        cx.advanceFrameClock();
        cx.requestRedraw();
        _ = cx.render();
    }
    try std.testing.expect(cx.focus_manager.getFocused() == outside.input_container);
}

const Window = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    source: *layers.View,
    card: *ui.Node,
    content: *ui.Node,

    fn init() !Window {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(1440, 900);
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        errdefer scope.dispose();
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        const source = try layers.View.mount(cx, scope);
        try cx.root.?.appendChild(cx.allocator, source.root);
        const workspace = try ui.box(cx, .{ .position = .absolute, .width = .{ .px = 400 }, .height = .{ .px = 300 }, .inset = .{ .left = .{ .px = 500 }, .top = .{ .px = 300 } }, .background = ui.Color.hex(0xff0011) }, .{});
        workspace.meta.ownership.meta.test_id = "workspace.body";
        try workspace.appendChild(cx.allocator, try ui.text(cx, "打开终端，开始工作", .{ .font_size = 24, .color = ui.Color.WHITE }));
        try cx.root.?.appendChild(cx.allocator, workspace);
        const holder = try ui.box(cx, .{ .position = .absolute, .width = .fill(), .height = .fill(), .align_items = .center, .justify = .center }, .{});
        try cx.root.?.appendChild(cx.allocator, holder);
        const card = try ui.boxStyled(cx, shell.settingsPanel, .{});
        try holder.appendChild(cx.allocator, card);
        const content = try ui.widgets.Button(.{ .label = "实际设置按钮" }).mount(scope, cx);
        try card.appendChild(cx.allocator, content);
        try source.isolate(scope, card);
        return .{ .cx = cx, .scope = scope, .source = source, .card = card, .content = content };
    }

    fn frame(self: Window) []const ui.DisplayItem {
        self.cx.frame_count += 1;
        self.cx.frame_time_ms += 16;
        _ = self.cx.render();
        self.cx.frame_count += 1;
        self.cx.frame_time_ms += 16;
        return self.cx.render();
    }

    fn deinit(self: Window) void {
        self.scope.dispose();
        self.cx.deinit();
    }
};

fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |value| return value;
    return null;
}

fn expectRect(a: ui.ComputedRect, b: ui.ComputedRect) !void {
    inline for (.{ "x", "y", "w", "h" }) |key| try std.testing.expectApproxEqAbs(@field(a, key), @field(b, key), 0.01);
}

fn imageCount(items: []const ui.DisplayItem, texture: u32) usize {
    var count: usize = 0;
    for (items) |item| switch (item) {
        .image_quad => |quad| if (quad.texture_id == texture) {
            count += 1;
        },
        else => {},
    };
    return count;
}

test "settings surface blocks blank area pointer and scroll hits from the terminal below" {
    const w = try Window.init();
    defer w.deinit();
    const terminal = find(w.cx.root.?, "workspace.body").?;
    terminal.setStyleInline(w.cx.allocator, .{ .hit_behavior = .@"opaque", .hit_roles = .{ .pointer = true, .scroll = true } });
    _ = w.frame();
    const rect = w.card.globalRect();
    // A point inside both the terminal and the settings card, below its button.
    const x = rect.x + rect.w / 2;
    const y = rect.y + rect.h / 2;
    try std.testing.expectEqual(w.card, w.cx.hitTest(x, y).?);
    const wheel = w.cx.hitTestQuery(.{ .kind = .scroll, .world_x = x, .world_y = y }).?;
    try std.testing.expectEqual(w.card.id, wheel.node_id);
    w.card.setDisplay(.none);
    _ = w.frame();
    try std.testing.expectEqual(terminal, w.cx.hitTest(x, y).?);
}

test "background preview reveals image at full global transparency and blurs its own surface" {
    const w = try Window.init();
    defer w.deinit();
    w.source.root.setStyleInline(w.cx.allocator, .{ .composited_group = true });
    var materials: assets.Materials = .{ .background = .{ .enabled = true, .path = "/fixture" } };
    const image: layers.Image = .{ .id = 777, .width = 640, .height = 256 };
    var previous_opacity: f32 = 1;
    for ([_]f32{ 0, 50, 100 }) |transparency| {
        materials.background.transparency = transparency;
        for ([_]u8{ 0, 24, 96 }) |blur| {
            materials.blur_px = blur;
            try w.source.update(image, materials, 1440, 900);
            _ = w.frame();
            const veil = w.source.veil.getBackground();
            const opacity = w.source.veil.getOpacity();
            try std.testing.expect(opacity <= previous_opacity);
            previous_opacity = opacity;
            try std.testing.expectEqual(@as(u8, 255), veil.a);
            try std.testing.expectEqual(1 - transparency / 100, opacity);
            try std.testing.expect(w.source.veil.style.composited_group());
            const glass = w.source.blur.style.glass_params().?;
            try std.testing.expect(glass.capture_current_target);
            try std.testing.expect(glass.capture_clamp);
            try std.testing.expectEqual(@as(f32, @floatFromInt(blur)), w.source.blur.style.backdrop_blur());
            try std.testing.expect((w.source.blur.style.display == .none) == (blur == 0));
        }
    }
}

test "global background remains the only image through floating card move resize hide and reopen" {
    const previous_parameters = theme.materialParameters();
    defer _ = theme.setMaterialParameters(previous_parameters.transparency, previous_parameters.blur);
    _ = theme.setMaterialParameters(75, 16);
    const w = try Window.init();
    defer w.deinit();
    var materials: assets.Materials = .{ .background = .{ .enabled = true, .path = "/fixture", .fit = .fit }, .blur_px = 12 };
    const image: layers.Image = .{ .id = 777, .width = 640, .height = 256 };
    const children = w.card.children.items.len;
    const hooks = w.cx.after_layout_hooks.items.len;
    try w.source.isolate(w.scope, w.card);
    _ = w.cx.render();
    try std.testing.expectEqual(children, w.card.children.items.len);
    try std.testing.expectEqual(hooks, w.cx.after_layout_hooks.items.len);
    try std.testing.expectEqual(@as(f32, 16), w.card.style.backdrop_blur());
    try std.testing.expect(!w.card.style.glass_params().?.capture_current_target);
    try std.testing.expect(find(w.card, "appearance.surface") == null);
    for ([_]assets.Fit{ .fill, .fit, .center, .tile }) |fit| {
        materials.background.fit = fit;
        // Tile uses a larger fixture to keep the test's paint stream small.
        try w.source.update(image, materials, 1440, 900);
        _ = w.frame();
        const original = w.source.tiles.items[0].globalRect();
        w.card.setStyleInline(w.cx.allocator, .{ .width = .{ .px = 620 }, .height = .{ .px = 500 }, .translate_x = 37, .translate_y = -17 });
        _ = w.frame();
        try expectRect(original, w.source.tiles.items[0].globalRect());
        try std.testing.expectEqual(children, w.card.children.items.len);
    }
    materials.background.fit = .fit;
    w.cx.setViewport(1600, 1000);
    try w.source.update(image, materials, 1600, 1000);
    for ([_]bool{ false, true, false, true }) |visible| {
        w.card.setDisplay(if (visible) .flex else .none);
        const items = w.frame();
        try std.testing.expectEqual(@as(usize, 1), imageCount(items, 777));
        var encoded: usize = 0;
        for (w.cx.lowering.main_paint.items) |item| if (item.kind == .image and item.resource_handle == 777) {
            encoded += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), encoded);
    }
    w.cx.setFocus(w.content);
    _ = w.frame();
    try std.testing.expectEqual(w.content, w.cx.focus_manager.getFocused().?);
    try std.testing.expectEqual(w.content, w.card.children.items[0]);
    const button_rect = w.content.globalRect();
    const hit = w.cx.hitTest(button_rect.x + button_rect.w / 2, button_rect.y + button_rect.h / 2).?;
    try std.testing.expect(hit == w.content or hit.isDescendantOf(w.content));
}

test "global base remains visible without an enabled decoded image and removes stale image effects" {
    const previous = theme.currentName();
    defer theme.select(previous);
    const w = try Window.init();
    defer w.deinit();
    const image: layers.Image = .{ .id = 777, .width = 640, .height = 256 };
    var materials: assets.Materials = .{ .background = .{ .enabled = true, .path = "/fixture", .fit = .fit }, .blur_px = 12 };
    for (std.enums.values(theme.Name)) |name| {
        theme.select(name);
        try w.source.update(image, materials, 1440, 900);
        try std.testing.expectEqual(@as(usize, 1), imageCount(w.frame(), 777));
        for ([_]bool{ false, true }) |enabled| {
            materials.background.enabled = enabled;
            try w.source.update(null, materials, 1440, 900);
            try std.testing.expectEqual(@as(usize, 0), imageCount(w.frame(), 777));
            try std.testing.expectEqual(.flex, w.source.root.style.display);
            try std.testing.expectEqual(theme.baseColors().app, w.source.root.getBackground());
            try std.testing.expectEqual(.none, w.source.images.style.display);
            try std.testing.expectEqual(.none, w.source.blur.style.display);
            try std.testing.expectEqual(.flex, w.source.veil.style.display);
        }
    }
}

test "global surface compatibility keeps target hierarchy and scope disposal independent" {
    const w = try Window.init();
    defer w.deinit();
    for ([_]bool{ false, true }) |destroy_first| {
        const child = try ui.Scope.init(std.testing.allocator, w.scope, w.cx.owner);
        const target = try ui.box(w.cx, .{}, .{});
        try w.cx.root.?.appendChild(w.cx.allocator, target);
        const hooks = w.cx.after_layout_hooks.items.len;
        try w.source.isolate(child, target);
        try w.source.isolate(child, target);
        try std.testing.expectEqual(@as(usize, 0), target.children.items.len);
        try std.testing.expectEqual(hooks, w.cx.after_layout_hooks.items.len);
        if (destroy_first) {
            w.cx.root.?.removeChild(target);
            w.cx.destroyDetached(target);
            try w.source.update(null, .{}, 1440, 900);
            child.dispose();
        } else {
            child.dispose();
            try std.testing.expectEqual(@as(usize, 0), target.children.items.len);
            w.cx.root.?.removeChild(target);
            w.cx.destroyDetached(target);
        }
        _ = w.frame();
    }
}

const detail = @import("ui/connection_details_view.zig");
const status_connection = @import("ui/status_connection_view.zig");
const authentication = @import("ui/auth_challenge_view.zig");
const operation: detail.OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(73), .generation = 1 } }, .operation_id = 16, .attempt_id = 1 };

fn detailSnapshot() !detail.Snapshot {
    var snapshot: detail.Snapshot = .{ .key = operation, .revision = 1, .source = .session, .hops = @splat(.{}), .hop_count = 1, .target_rtt_sample = null, .sampled_at = null };
    snapshot.hops[0].configured = true;
    snapshot.hops[0].status = .online;
    snapshot.hops[0].endpoint = .{ .name = try detail.details.Text(512).init("Original target"), .host = try detail.details.Text(1024).init("target.example"), .user = try detail.details.Text(256).init("operator") };
    return snapshot;
}

test "global background survives real connection and status foreground rebuilds and lazy node dialog" {
    const previous = theme.currentName();
    const visible = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(visible);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(true);
    const w = try Window.init();
    defer w.deinit();
    const snapshot = try detailSnapshot();
    const view = try detail.View.mount(w.cx, w.scope, .{ .context = w.source });
    try w.cx.root.?.appendChild(w.cx.allocator, view.root);
    try view.setMaterial(w.source);
    try std.testing.expect(find(view.chrome, "appearance.surface") == null);
    const Callback = struct {
        fn copy(_: *anyopaque, _: detail.OperationKey, _: []const u8) !void {}
    };
    const info = try status_connection.View.mount(w.cx, w.scope, .{ .context = w.source, .copy = Callback.copy });
    try w.cx.root.?.appendChild(w.cx.allocator, info.root);
    try w.source.isolate(info.scope, info.chrome);
    try std.testing.expect(find(info.chrome, "appearance.surface") == null);
    const material: assets.Materials = .{ .background = .{ .enabled = true, .path = "/fixture" } };
    try w.source.update(.{ .id = 777, .width = 640, .height = 256 }, material, 1440, 900);
    _ = w.frame();
    try view.show(snapshot, w.content, 860);
    var info_snapshot: status_connection.Snapshot = .{ .key = operation, .revision = 1, .endpoint = snapshot.hops[0].endpoint, .state = .online, .hop_count = 1 };
    info_snapshot.route[0] = info_snapshot.endpoint;
    try info.show(info_snapshot, w.content, 860);
    for (0..3) |_| {
        try view.retheme();
        try view.flush();
        try std.testing.expect(find(view.chrome, "appearance.surface") == null);
        try info.retheme();
        try std.testing.expect(find(info.chrome, "appearance.surface") == null);
        _ = w.frame();
        try std.testing.expect(find(view.chrome, "appearance.surface") == null);
        try std.testing.expect(find(info.chrome, "appearance.surface") == null);
        try std.testing.expectEqual(@as(usize, 1), imageCount(w.frame(), 777));
    }
    // Both popovers belong to the workspace group. Reopen the route card
    // after exercising the status card so the node selection reaches it.
    try view.show(snapshot, w.content, 860);
    _ = w.frame();
    try std.testing.expect(view.isVisible());
    try std.testing.expect(!info.isVisible());
    try std.testing.expect(view.node_modal == null);
    view.pending_selection = .{ .hop = 0 };
    try view.flush();
    _ = w.frame();
    try std.testing.expect(view.node_open.peek());
    const modal = view.node_modal orelse return error.ExpectedNodeDialog;
    try std.testing.expect(find(modal.dialog, "appearance.surface") == null);
    var newer = snapshot;
    newer.revision = 2;
    try view.update(newer);
    try view.flush();
    _ = w.frame();
    try std.testing.expect(view.node_open.peek());
    try std.testing.expectEqual(modal.dialog, (view.node_modal orelse return error.ExpectedNodeDialog).dialog);
    try std.testing.expect(find(modal.dialog, "appearance.surface") == null);
    try std.testing.expectEqual(@as(usize, 1), imageCount(w.frame(), 777));
}

test "global background supports authentication created after startup and remains across challenges" {
    const previous = theme.currentName();
    const visible = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(visible);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(true);
    const w = try Window.init();
    defer w.deinit();
    const Callbacks = struct {
        fn submit(_: *anyopaque, _: authentication.auth.RequestIdentity, _: authentication.auth.Reply) !void {}
        fn cancel(_: *anyopaque, _: authentication.auth.RequestIdentity) void {}
    };
    const auth = try authentication.View.mount(w.cx, w.scope, .{ .context = w.source, .submit = Callbacks.submit, .cancel = Callbacks.cancel });
    try w.cx.root.?.appendChild(w.cx.allocator, auth.root);
    try auth.setMaterial(w.source);
    try std.testing.expect(auth.modal == null);
    const material: assets.Materials = .{ .background = .{ .enabled = true, .path = "/fixture" } };
    try w.source.update(.{ .id = 777, .width = 640, .height = 256 }, material, 1440, 900);
    var bridge: authentication.auth.InteractiveBridge = .{};
    _ = try bridge.offerChallenge(.{ .key = operation, .hop_index = 0, .kind = .host_key_unknown, .endpoint_identity = .{ .host = "target.example", .user = "operator", .port = 22 }, .prompts = &.{}, .presentation = .otp_modal, .presentation_config_revision = 1 });
    try auth.show(bridge.snapshot().?);
    _ = w.frame();
    try std.testing.expect(find(auth.modal.?.dialog, "appearance.surface") == null);
    try std.testing.expectEqual(@as(usize, 1), imageCount(w.frame(), 777));
    auth.hide();
    bridge.cancel();
    bridge = .{};
    var next_operation = operation;
    next_operation.operation_id += 1;
    _ = try bridge.offerChallenge(.{ .key = next_operation, .hop_index = 0, .kind = .password, .endpoint_identity = .{ .host = "target.example", .user = "operator", .port = 22 }, .prompts = &.{.{ .text = "Password:", .echo = false }}, .presentation = .otp_modal, .presentation_config_revision = 1 });
    try auth.show(bridge.snapshot().?);
    _ = w.frame();
    try std.testing.expect(find(auth.modal.?.dialog, "appearance.surface") == null);
    try std.testing.expectEqual(@as(usize, 1), imageCount(w.frame(), 777));
    bridge.cancel();
}
