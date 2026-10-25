//! One window-space material below every foreground control. Terminals reveal
//! this same layer, so their image scale, alignment and tile phase cannot drift.
const std = @import("std");
const ui = @import("ui");
const material = @import("../config/background_asset.zig");
const geometry = @import("../config/background_geometry.zig");
const repeat = @import("background_repeat.zig");
pub const Image = struct { id: u32, width: u32, height: u32, repeating: ?repeat.Texture = null };
const theme = @import("app_theme.zig");

/// Compatibility for foreground rebuilders: global material has no surface nodes.
pub fn isSurface(_: *const ui.Node) bool {
    return false;
}

pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    images: *ui.Node,
    blur: *ui.Node,
    veil: *ui.Node,
    tiles: std.ArrayList(*ui.Node) = .empty,
    fingerprint: ?u64 = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope) !*View {
        const self = try cx.allocator.create(View);
        errdefer cx.allocator.destroy(self);
        const root = try ui.box(cx, layer(), .{});
        root.meta.ownership.meta.test_id = "appearance.background";
        root.setStyleInline(cx.allocator, .{ .overflow = .hidden, .background = theme.baseColors().app });
        const images = try ui.box(cx, layer(), .{});
        const blur = try ui.box(cx, layer(), .{});
        const veil = try ui.box(cx, layer(), .{});
        try root.appendChild(cx.allocator, images);
        try root.appendChild(cx.allocator, blur);
        try root.appendChild(cx.allocator, veil);
        images.setDisplay(.none);
        blur.setDisplay(.none);
        veil.setDisplay(.none);
        self.* = .{ .cx = cx, .root = root, .images = images, .blur = blur, .veil = veil };
        try scope.onCleanup(View, self, cleanup);
        return self;
    }

    /// Called at the host's safe point. Only decoded/uploaded resources enter;
    /// it never reads a file, changes settings or creates a second image fit.
    pub fn update(self: *View, texture: ?Image, materials: material.Materials, width: f32, height: f32) !void {
        try self.paint(texture, materials, width, height);
    }

    /// Float chrome filters only the backdrop already painted behind it.
    /// Its own text and controls render afterward; no image/floor nodes,
    /// layout hooks or target borrows are retained by the global material.
    pub fn isolate(self: *View, scope: *ui.Scope, target: *ui.Node) !void {
        try scope.createEffect(.{ .cx = self.cx, .target = target, .publication = try self.cx.themeSignal(scope) }, struct {
            fn paint(ctx: anytype) void {
                _ = ctx.publication.get();
                ctx.target.setStyleInline(ctx.cx.allocator, .{ .glass = theme.overlayGlass() });
            }
        }.paint);
    }

    fn paint(self: *View, texture: ?Image, materials: material.Materials, width: f32, height: f32) !void {
        try materials.validate();
        if (!materials.background.enabled or texture == null) {
            self.root.setBackground(theme.baseColors().app);
            self.root.setDisplay(.flex);
            self.images.setDisplay(.none);
            self.blur.setDisplay(.none);
            self.veil.setDisplay(.none);
            self.fingerprint = null;
            return;
        }
        const image = texture.?;
        const background = materials.background;
        const transform = try geometry.resolve(.{ .source = .{ .pixel_width = image.width, .pixel_height = image.height }, .window = .{ .width = width, .height = height }, .fit = background.fit, .horizontal = background.alignment_x, .vertical = background.alignment_y });
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, .{ image.id, image.width, image.height, image.repeating, @as(u32, @bitCast(width)), @as(u32, @bitCast(height)), background.fit, background.alignment_x, background.alignment_y, @as(u32, @bitCast(background.transparency)), materials.blur_px, theme.baseColors().app });
        const fingerprint = hash.final();
        if (self.fingerprint == fingerprint) return;
        var rect = transform.image;
        var texture_id = image.id;
        if (transform.repeats) if (image.repeating) |repeating| {
            if (repeating.width < image.width or repeating.height < image.height or repeating.width % image.width != 0 or repeating.height % image.height != 0) return error.InvalidRepeatingTexture;
            // Preserve the original alignment phase; only the integer period
            // gets larger. Other fit modes continue drawing the source image.
            rect.width *= @as(f64, @floatFromInt(repeating.width / image.width));
            rect.height *= @as(f64, @floatFromInt(repeating.height / image.height));
            texture_id = repeating.id;
        };
        const tiled = if (transform.repeats) try repeat.grid(width, height, rect.x, rect.y, rect.width, rect.height) else null;
        const first_x = if (tiled) |value| value.first_x else rect.x;
        const first_y = if (tiled) |value| value.first_y else rect.y;
        const cols = if (tiled) |value| value.cols else 1;
        const count = if (tiled) |value| value.count else 1;
        try self.tiles.ensureTotalCapacity(self.cx.allocator, count);
        while (self.tiles.items.len < count) {
            const node = try ui.image(self.cx, texture_id, .{ .position = .absolute, .flex_shrink = 0 });
            errdefer self.cx.destroyDetached(node);
            try self.images.appendChild(self.cx.allocator, node);
            self.tiles.appendAssumeCapacity(node);
        }
        for (self.tiles.items, 0..) |node, index| {
            node.setDisplay(if (index < count) .flex else .none);
            if (index >= count) continue;
            const col = index % cols;
            const row = index / cols;
            node.setImage(.{ .texture_id = texture_id });
            node.setStyleInline(self.cx.allocator, .{ .position = .absolute, .width = .{ .px = @floatCast(rect.width) }, .height = .{ .px = @floatCast(rect.height) }, .inset = .{ .left = .{ .px = @floatCast(first_x + @as(f64, @floatFromInt(col)) * rect.width) }, .top = .{ .px = @floatCast(first_y + @as(f64, @floatFromInt(row)) * rect.height) } } });
        }
        self.root.setBackground(theme.baseColors().app);
        self.images.setDisplay(.flex);
        self.veil.setDisplay(.flex);
        self.blur.setStyleInline(self.cx.allocator, .{ .glass = .{ .backdrop_blur = @floatFromInt(materials.blur_px), .glass_intensity = 0, .specular_opacity = 0, .refraction_level = 0, .warp_gain = 0 }, .background = ui.Color.TRANSPARENT });
        self.blur.setDisplay(if (materials.blur_px == 0) .none else .flex);
        // Alpha applies to the image result only: foreground nodes remain 1.0.
        self.veil.setBackground(theme.baseColors().app.withAlpha(@intFromFloat(@round(background.transparency * 255 / 100))));
        self.root.setDisplay(.flex);
        self.fingerprint = fingerprint;
        self.cx.requestRedraw();
    }
    fn layer() ui.BoxStyle {
        return .{ .hit_behavior = .pass_through, .hit_roles = .{ .pointer = false, .scroll = false, .inspect = false }, .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .right = .{ .px = 0 }, .top = .{ .px = 0 }, .bottom = .{ .px = 0 } }, .width = .fill(), .height = .fill() };
    }
    fn cleanup(self: *View) void {
        self.tiles.deinit(self.cx.allocator);
        self.cx.allocator.destroy(self);
    }
};

test "background repeat layer uses the atlas only for Tile and keeps original fit coordinates" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const view = try View.mount(cx, scope);
    cx.root = view.root;
    cx.setViewport(1440, 900);
    const image: Image = .{ .id = 7, .width = 3, .height = 5, .repeating = .{ .id = 8, .width = 66, .height = 65 } };
    var materials: material.Materials = .{ .background = .{ .enabled = true, .path = "/fixture", .fit = .tile } };
    try view.update(image, materials, 1440, 900);
    cx.layout();
    try std.testing.expect(view.tiles.items.len <= 24 * 16);
    const first = view.tiles.items[0];
    try std.testing.expectEqual(@as(u32, 8), first.getImage().?.texture_id);
    try std.testing.expectEqual(@as(f32, 66), first.globalRect().w);
    try std.testing.expectEqual(@as(f32, 65), first.globalRect().h);
    try std.testing.expectEqual(@as(f32, -7.5), first.globalRect().x);
    try std.testing.expectEqual(@as(f32, -7.5), first.globalRect().y);

    const Case = struct { fit: material.Fit, x: f32, y: f32, width: f32, height: f32 };
    for ([_]Case{
        .{ .fit = .fill, .x = 0, .y = -750, .width = 1440, .height = 2400 },
        .{ .fit = .fit, .x = 450, .y = 0, .width = 540, .height = 900 },
        .{ .fit = .center, .x = 718.5, .y = 447.5, .width = 3, .height = 5 },
    }) |case| {
        materials.background.fit = case.fit;
        try view.update(image, materials, 1440, 900);
        cx.layout();
        try std.testing.expectEqual(@as(u32, 7), first.getImage().?.texture_id);
        const rect = first.globalRect();
        try std.testing.expectEqual(case.x, rect.x);
        try std.testing.expectEqual(case.y, rect.y);
        try std.testing.expectEqual(case.width, rect.w);
        try std.testing.expectEqual(case.height, rect.h);
        for (view.tiles.items[1..]) |node| try std.testing.expectEqual(.none, node.style.display);
    }
}

test "global material leaves the single image veil and window geometry independent of chrome alpha" {
    const previous = theme.currentName();
    const was_visible = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(was_visible);
    }
    _ = theme.setMaterialVisible(true);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const view = try View.mount(cx, scope);
    cx.root = view.root;
    cx.setViewport(1440, 900);
    var materials: material.Materials = .{ .background = .{ .enabled = true, .path = "/fixture", .fit = .fit } };
    for (std.enums.values(theme.Name)) |name| {
        theme.select(name);
        for ([_]f32{ 0, 50, 100 }) |percent| {
            materials.background.transparency = percent;
            try view.update(.{ .id = 7, .width = 320, .height = 180 }, materials, 1440, 900);
            cx.layout();
            try std.testing.expectEqual(@as(u8, 0), theme.current().app.a);
            try std.testing.expectEqual(theme.baseColors().app, view.root.getBackground());
            try std.testing.expectEqual(theme.baseColors().app.withAlpha(@intFromFloat(@round(percent * 255 / 100))), view.veil.getBackground());
            const rect = view.tiles.items[0].globalRect();
            try std.testing.expectApproxEqAbs(@as(f32, 0), rect.x, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 45), rect.y, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 1440), rect.w, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 810), rect.h, 0.01);
        }
    }
}

test "global material publication updates retained popup blur including zero without rebuilding" {
    const saved = theme.materialParameters();
    defer _ = theme.setMaterialParameters(saved.transparency, saved.blur);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const view = try View.mount(cx, scope);
    cx.root = view.root;
    const popup = try ui.box(cx, .{}, .{});
    try view.root.appendChild(cx.allocator, popup);
    try view.isolate(scope, popup);
    var publication: @import("shell_styles.zig").ThemePublication = .{};
    for ([_]f32{ 24, 0, 96 }) |blur| {
        _ = theme.setMaterialParameters(75, blur);
        publication.publish(cx, theme.widgetTheme(theme.currentName()));
        _ = cx.render();
        try std.testing.expectEqual(blur, popup.style.backdrop_blur());
    }
}
