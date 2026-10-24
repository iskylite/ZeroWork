//! No-window production Cx/render checks for floating global material surfaces.
const std = @import("std");
const ui = @import("ui");
const layers = @import("ui/background_layers.zig");
const assets = @import("config/background_asset.zig");
const theme = @import("ui/app_theme.zig");
const shell = @import("ui/shell_styles.zig");

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

fn expectImages(source: *ui.Node, projection: *ui.Node) !void {
    try std.testing.expectEqual(source.children.items.len, projection.children.items.len);
    for (source.children.items, projection.children.items) |a, b| {
        try std.testing.expectEqual(a.style.display, b.style.display);
        if (a.style.display == .none) continue;
        try std.testing.expectEqual(a.getImage().?.texture_id, b.getImage().?.texture_id);
        try expectRect(a.globalRect(), b.globalRect());
    }
}

test "isolated material render covers workspace before image and original surface tint while keeping controls" {
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
    const image: layers.Image = .{ .id = 777, .width = 640, .height = 256 };
    const materials: assets.Materials = .{ .background = .{ .enabled = true, .path = "/fixture", .fit = .fit, .transparency = 50 } };
    try w.source.update(image, materials, 1440, 900);
    const items = w.frame();
    const surface = find(w.card, "appearance.surface").?;
    const plane = surface.children.items[0];
    const floor = plane.children.items[0];
    const images = plane.children.items[1];
    const tint = plane.children.items[4];
    const workspace = find(w.cx.root.?, "workspace.body").?;
    try std.testing.expectEqual(surface, w.card.children.items[0]);
    try std.testing.expectEqual(w.content, w.card.children.items[1]);
    try std.testing.expectEqual(@as(u8, 255), floor.getBackground().a);
    try std.testing.expectEqual(w.card.getBackground(), tint.getBackground());
    try std.testing.expectEqual(theme.current().overlay, tint.getBackground());
    try std.testing.expectEqual(@as(f32, 14), surface.style.corner_radius().?.resolve());
    try std.testing.expect(surface.style.overflow_hidden);
    try expectRect(w.card.globalRect(), surface.globalRect());
    try expectRect(ui.ComputedRect.init(0, 0, 1440, 900), plane.globalRect());
    try expectImages(w.source.images, images);
    var body_order: ?usize = null;
    var floor_order: ?usize = null;
    var image_order: ?usize = null;
    var tint_order: ?usize = null;
    var floor_count: usize = 0;
    var image_count: usize = 0;
    var tint_count: usize = 0;
    for (items, 0..) |item, index| switch (item) {
        .fill_rect => |fill| {
            if (fill.header.node_id == workspace.id) body_order = index;
            if (fill.header.node_id == floor.id and fill.color.a == 255) {
                floor_order = index;
                floor_count += 1;
            }
            if (fill.header.node_id == tint.id) {
                tint_order = index;
                tint_count += 1;
            }
        },
        .image_quad => |quad| if (quad.header.node_id == images.children.items[0].id) {
            image_order = index;
            image_count += 1;
        },
        else => {},
    };
    try std.testing.expect(body_order != null and floor_order != null and image_order != null and tint_order != null);
    try std.testing.expect(body_order.? < floor_order.? and floor_order.? < image_order.? and image_order.? < tint_order.?);
    try std.testing.expectEqual(@as(usize, 1), floor_count);
    try std.testing.expectEqual(@as(usize, 1), image_count);
    try std.testing.expectEqual(@as(usize, 1), tint_count);
    // The material has no hit/scroll role and does not replace the focused control.
    w.cx.setFocus(w.content);
    _ = w.frame();
    try std.testing.expectEqual(w.content, w.cx.focus_manager.getFocused().?);
    try std.testing.expectEqual(.pass_through, surface.style.hit_behavior().?);
}

test "isolated material keeps window fit tile phase after move resize theme and image visibility" {
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
    const image: layers.Image = .{ .id = 7, .width = 3, .height = 5, .repeating = .{ .id = 8, .width = 66, .height = 65 } };
    var materials: assets.Materials = .{ .background = .{ .enabled = true, .path = "/fixture" }, .blur_px = 12 };
    const surface = find(w.card, "appearance.surface").?;
    const plane = surface.children.items[0];
    const floor = plane.children.items[0];
    const images = plane.children.items[1];
    const blur = plane.children.items[2];
    const veil = plane.children.items[3];
    // Ordinary glass keeps the window backdrop. Only the image-only material
    // opts into the raw pixels already drawn in its own isolated target.
    const default_glass: ui.GlassParams = .{};
    try std.testing.expect(!default_glass.capture_current_target);
    try std.testing.expect(!default_glass.resolve().capture_current_target);
    for ([_]assets.Fit{ .fill, .fit, .center, .tile }) |fit| {
        materials.background.fit = fit;
        try w.source.update(image, materials, 1440, 900);
        _ = w.frame();
        try expectImages(w.source.images, images);
        try std.testing.expectEqual(@as(f32, 12), blur.style.backdrop_blur());
        try std.testing.expect(!w.source.blur.style.glass_params().?.capture_current_target);
        try std.testing.expect(blur.style.glass_params().?.capture_current_target);
        try std.testing.expect(blur.style.glass_params().?.resolve().capture_current_target);
        try std.testing.expectEqual(w.source.veil.getBackground(), veil.getBackground());
    }
    w.card.setStyleInline(w.cx.allocator, .{ .width = .{ .px = 620 }, .height = .{ .px = 500 }, .translate_x = 37, .translate_y = -17 });
    _ = w.frame();
    try expectRect(w.card.globalRect(), surface.globalRect());
    try expectImages(w.source.images, images);
    w.cx.setViewport(1600, 1000);
    try w.source.update(image, materials, 1600, 1000);
    _ = w.frame();
    try expectRect(ui.ComputedRect.init(0, 0, 1600, 1000), plane.globalRect());
    try expectImages(w.source.images, images);
    const publication = try w.cx.bindState(shell.ThemePublication, .{});
    for (std.enums.values(theme.Name)) |name| {
        theme.select(name);
        publication.publish(w.cx, theme.widgetTheme(name));
        for ([_]f32{ 0, 50, 100 }) |transparency| {
            materials.background.transparency = transparency;
            try w.source.update(image, materials, 1600, 1000);
            _ = w.frame();
            try std.testing.expectEqual(theme.baseColors().app.withAlpha(255), floor.getBackground());
            try std.testing.expectEqual(w.card.getBackground(), plane.children.items[4].getBackground());
            try std.testing.expectEqual(w.source.veil.getBackground(), veil.getBackground());
        }
    }
    materials.background.enabled = false;
    try w.source.update(null, materials, 1600, 1000);
    _ = w.frame();
    try std.testing.expectEqual(.none, surface.style.display);
    try std.testing.expectEqual(w.content, w.card.children.items[1]);
    materials.background.enabled = true;
    try w.source.update(image, materials, 1600, 1000);
    _ = w.frame();
    try std.testing.expectEqual(.flex, surface.style.display);
    try expectImages(w.source.images, images);
}

test "isolated material registration is idempotent and child scope removes nodes and hooks" {
    const w = try Window.init();
    defer w.deinit();
    const child = try ui.Scope.init(std.testing.allocator, w.scope, w.cx.owner);
    const target = try ui.box(w.cx, .{ .width = .{ .px = 120 }, .height = .{ .px = 90 } }, .{});
    try w.cx.root.?.appendChild(w.cx.allocator, target);
    const hooks = w.cx.after_layout_hooks.items.len;
    try w.source.isolate(child, target);
    try w.source.isolate(child, target);
    try std.testing.expectEqual(@as(usize, 2), w.source.surfaces.items.len);
    try std.testing.expectEqual(@as(usize, 1), target.children.items.len);
    try std.testing.expectEqual(hooks + 1, w.cx.after_layout_hooks.items.len);
    child.dispose();
    try std.testing.expectEqual(@as(usize, 1), w.source.surfaces.items.len);
    try std.testing.expectEqual(@as(usize, 0), target.children.items.len);
    try std.testing.expectEqual(hooks, w.cx.after_layout_hooks.items.len);
    _ = w.frame();
}

test "isolated material hide and reopen leave no image residue in the encoder paint stream" {
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
    const materials: assets.Materials = .{ .background = .{ .enabled = true, .path = "/fixture", .fit = .fit, .transparency = 50 } };
    try w.source.update(.{ .id = 777, .width = 640, .height = 256 }, materials, 1440, 900);
    for (0..4) |_| {
        w.card.setDisplay(.flex);
        for (0..4) |_| {
            const items = w.frame();
            var image_count: usize = 0;
            for (items) |item| switch (item) {
                .image_quad => |image| if (image.texture_id == 777) {
                    image_count += 1;
                },
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 2), image_count);
            var encoder_images: usize = 0;
            for (w.cx.lowering.main_paint.items) |item| if (item.kind == .image and item.resource_handle == 777) {
                encoder_images += 1;
            };
            try std.testing.expectEqual(@as(usize, 2), encoder_images);
        }
        w.card.setDisplay(.none);
        for (0..4) |_| {
            w.cx.requestRedraw();
            const items = w.frame();
            var image_count: usize = 0;
            for (items) |item| switch (item) {
                .image_quad => |image| if (image.texture_id == 777) {
                    image_count += 1;
                },
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 1), image_count);
            var encoder_images: usize = 0;
            for (w.cx.lowering.main_paint.items) |item| if (item.kind == .image and item.resource_handle == 777) {
                encoder_images += 1;
            };
            try std.testing.expectEqual(@as(usize, 1), encoder_images);
        }
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

test "isolated material survives real connection and status foreground rebuilds and lazy node dialog" {
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
    const material_node = find(view.chrome, "appearance.surface").?;
    const Callback = struct {
        fn copy(_: *anyopaque, _: detail.OperationKey, _: []const u8) !void {}
    };
    const info = try status_connection.View.mount(w.cx, w.scope, .{ .context = w.source, .copy = Callback.copy });
    try w.cx.root.?.appendChild(w.cx.allocator, info.root);
    try w.source.isolate(info.scope, info.chrome);
    const info_material = find(info.chrome, "appearance.surface").?;
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
        try std.testing.expectEqual(material_node, find(view.chrome, "appearance.surface").?);
        try info.retheme();
        try std.testing.expectEqual(info_material, find(info.chrome, "appearance.surface").?);
        _ = w.frame();
        try std.testing.expectEqual(material_node, find(view.chrome, "appearance.surface").?);
        try std.testing.expectEqual(info_material, find(info.chrome, "appearance.surface").?);
        try std.testing.expectEqual(.flex, material_node.style.display);
        try std.testing.expectEqual(.flex, info_material.style.display);
    }
    view.pending_selection = .{ .hop = 0 };
    try view.flush();
    _ = w.frame();
    const node_material = find(view.node_modal.?.dialog, "appearance.surface").?;
    try std.testing.expectEqual(.flex, node_material.style.display);
    var newer = snapshot;
    newer.revision = 2;
    try view.update(newer);
    try view.flush();
    _ = w.frame();
    try std.testing.expectEqual(node_material, find(view.node_modal.?.dialog, "appearance.surface").?);
}

test "isolated material binds authentication created after startup and remains across challenges" {
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
    const surface = find(auth.modal.?.dialog, "appearance.surface").?;
    try std.testing.expectEqual(.flex, surface.style.display);
    auth.hide();
    bridge.cancel();
    bridge = .{};
    var next_operation = operation;
    next_operation.operation_id += 1;
    _ = try bridge.offerChallenge(.{ .key = next_operation, .hop_index = 0, .kind = .password, .endpoint_identity = .{ .host = "target.example", .user = "operator", .port = 22 }, .prompts = &.{.{ .text = "Password:", .echo = false }}, .presentation = .otp_modal, .presentation_config_revision = 1 });
    try auth.show(bridge.snapshot().?);
    _ = w.frame();
    try std.testing.expectEqual(surface, find(auth.modal.?.dialog, "appearance.surface").?);
    try std.testing.expectEqual(.flex, surface.style.display);
    bridge.cancel();
}
