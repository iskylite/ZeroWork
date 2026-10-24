//! One window-space material below every foreground control. Terminals reveal
//! this same layer, so their image scale, alignment and tile phase cannot drift.
const std = @import("std");
const ui = @import("ui");
const material = @import("../config/background_asset.zig");
const geometry = @import("../config/background_geometry.zig");
const repeat = @import("background_repeat.zig");
pub const Image = struct { id: u32, width: u32, height: u32, repeating: ?repeat.Texture = null };
const theme = @import("app_theme.zig");

/// Rebuilt foreground trees retain this window-owned first child. Disposing
/// the registered surface scope removes it and its after-layout hook together.
pub fn isSurface(node: *const ui.Node) bool {
    const id = node.meta.ownership.meta.test_id orelse return false;
    return std.mem.eql(u8, id, "appearance.surface");
}

pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    images: *ui.Node,
    blur: *ui.Node,
    veil: *ui.Node,
    tiles: std.ArrayList(*ui.Node) = .empty,
    surfaces: std.ArrayList(*Surface) = .empty,
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
        root.setDisplay(.none);
        self.* = .{ .cx = cx, .root = root, .images = images, .blur = blur, .veil = veil };
        try scope.onCleanup(View, self, cleanup);
        return self;
    }

    /// Called at the host's safe point. Only decoded/uploaded resources enter;
    /// it never reads a file, changes settings or creates a second image fit.
    pub fn update(self: *View, texture: ?Image, materials: material.Materials, width: f32, height: f32) !void {
        try self.paint(texture, materials, width, height);
        for (self.surfaces.items) |surface| _ = try surface.sync();
    }

    /// Give a floating surface its own material floor. Its first child covers
    /// workspace content, then projects this same window-space image and the
    /// surface's existing tint. No texture upload, fit or settings are owned
    /// by the surface. The supplied scope must not outlive this View or target.
    pub fn isolate(self: *View, scope: *ui.Scope, target: *ui.Node) !void {
        for (self.surfaces.items) |surface| if (surface.target == target) return;
        try self.surfaces.ensureUnusedCapacity(self.cx.allocator, 1);
        const surface = try Surface.mount(self, scope, target);
        self.surfaces.appendAssumeCapacity(surface);
    }

    fn paint(self: *View, texture: ?Image, materials: material.Materials, width: f32, height: f32) !void {
        try materials.validate();
        if (!materials.background.enabled or texture == null) {
            self.root.setDisplay(.none);
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
        self.blur.setStyleInline(self.cx.allocator, .{ .glass = .{ .backdrop_blur = @floatFromInt(materials.blur_px), .glass_intensity = 0, .specular_opacity = 0, .refraction_level = 0, .warp_gain = 0 }, .background = ui.Color.TRANSPARENT });
        self.blur.setDisplay(if (materials.blur_px == 0) .none else .flex);
        // Alpha applies to the image result only: foreground nodes remain 1.0.
        self.veil.setBackground(theme.baseColors().app.withAlpha(@intFromFloat(@round(background.transparency * 255 / 100))));
        self.root.setDisplay(.flex);
        self.fingerprint = fingerprint;
        self.cx.requestRedraw();
    }
    fn layer() ui.BoxStyle {
        return .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .right = .{ .px = 0 }, .top = .{ .px = 0 }, .bottom = .{ .px = 0 } }, .width = .fill(), .height = .fill() };
    }
    fn cleanup(self: *View) void {
        std.debug.assert(self.surfaces.items.len == 0);
        self.surfaces.deinit(self.cx.allocator);
        self.tiles.deinit(self.cx.allocator);
        self.cx.allocator.destroy(self);
    }
};

/// Window-aligned image-only backing for a floating card. Ordinary translucent
/// chrome may reveal workspace content; a dialog must reveal only the global
/// material. A rounded, opaque floor prevents text/buttons below the dialog
/// from participating in its material, including at 100% image transparency.
const Surface = struct {
    cx: *ui.Cx,
    source: ?*View,
    root_alive: bool = true,
    target: *ui.Node,
    root: *ui.Node,
    plane: *ui.Node,
    floor: *ui.Node,
    images: *ui.Node,
    blur: *ui.Node,
    veil: *ui.Node,
    tint: *ui.Node,
    tiles: std.ArrayList(*ui.Node) = .empty,
    fingerprint: ?u64 = null,

    fn mount(source: *View, scope: *ui.Scope, target: *ui.Node) !*Surface {
        const cx = source.cx;
        const self = try cx.allocator.create(Surface);
        errdefer cx.allocator.destroy(self);
        const root = try ui.box(cx, decorativeLayer(), .{});
        errdefer {
            if (root.parent) |parent| parent.removeChild(root);
            cx.destroyDetached(root);
        }
        root.meta.ownership.meta.test_id = "appearance.surface";
        root.setDisplay(.none);
        const plane = try ui.box(cx, decorativeLayer(), .{});
        try root.appendChild(cx.allocator, plane);
        const floor = try ui.box(cx, decorativeLayer(), .{});
        try plane.appendChild(cx.allocator, floor);
        const images = try ui.box(cx, decorativeLayer(), .{});
        try plane.appendChild(cx.allocator, images);
        const blur = try ui.box(cx, decorativeLayer(), .{});
        try plane.appendChild(cx.allocator, blur);
        const veil = try ui.box(cx, decorativeLayer(), .{});
        try plane.appendChild(cx.allocator, veil);
        const tint = try ui.box(cx, decorativeLayer(), .{});
        try plane.appendChild(cx.allocator, tint);
        self.* = .{ .cx = cx, .source = source, .target = target, .root = root, .plane = plane, .floor = floor, .images = images, .blur = blur, .veil = veil, .tint = tint };
        root.meta.ownership.hooks.on_cleanup = .{ .context = self, .callback = rootGone };
        try target.insertChildBefore(cx.allocator, root, if (target.children.items.len > 0) target.children.items[0] else null);
        try cx.addAfterLayoutHook(self, afterLayout);
        errdefer cx.removeAfterLayoutHook(self);
        // Modal/Popover own an inner render scope which is disposed before
        // the caller's scope. Remove our hook before that scope frees its
        // portal tree; ModalResult intentionally exposes no scope field.
        var owner = target;
        var owner_scope = scope;
        while (true) {
            if (owner.meta.ownership.scope.scope) |bound| {
                owner_scope = bound;
                break;
            }
            owner = owner.parent orelse break;
        }
        try owner_scope.onCleanup(Surface, self, cleanup);
        return self;
    }

    fn decorativeLayer() ui.BoxStyle {
        var style = View.layer();
        style.hit_behavior = .pass_through;
        style.hit_roles = .{ .pointer = false, .scroll = false, .inspect = false };
        return style;
    }

    fn sync(self: *Surface) !bool {
        const source = self.source orelse return false;
        const cx = self.cx;
        if (source.fingerprint == null or source.root.style.display == .none) {
            const changed = self.root.style.display != .none;
            self.root.setDisplay(.none);
            self.fingerprint = null;
            return changed;
        }
        const rect = self.target.globalRect();
        if (rect.w <= 0 or rect.h <= 0) return false;
        const tint = self.target.getBackground();
        const radii = self.target.style.corner_radius() orelse ui.CornerRadius.uniform(self.target.style.border.radius);
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, .{ source.fingerprint, @as(u32, @bitCast(rect.x)), @as(u32, @bitCast(rect.y)), @as(u32, @bitCast(rect.w)), @as(u32, @bitCast(rect.h)), tint, @as([4]u32, @bitCast(radii.resolve4())), @as(u32, @bitCast(cx.viewport.width)), @as(u32, @bitCast(cx.viewport.height)) });
        const fingerprint = hash.final();
        if (self.fingerprint == fingerprint) return false;
        try self.tiles.ensureTotalCapacity(cx.allocator, source.tiles.items.len);
        while (self.tiles.items.len < source.tiles.items.len) {
            const node = try ui.image(cx, 0, .{ .position = .absolute, .flex_shrink = 0 });
            errdefer cx.destroyDetached(node);
            node.setHitTestVisible(false);
            try self.images.appendChild(cx.allocator, node);
            self.tiles.appendAssumeCapacity(node);
        }
        for (self.tiles.items, 0..) |node, index| {
            if (index >= source.tiles.items.len) {
                node.setDisplay(.none);
                continue;
            }
            const original = source.tiles.items[index];
            node.setDisplay(original.style.display);
            if (original.style.display == .none) continue;
            node.setImage(original.getImage().?);
            node.setStyleInline(cx.allocator, .{ .position = .absolute, .width = original.style.width, .height = original.style.height, .inset = original.style.inset() });
        }
        const floor = theme.baseColors().app.withAlpha(255);
        self.root.setStyleInline(cx.allocator, .{ .overflow = .hidden, .overflow_hidden = true, .corner_radii = radii });
        // The image plane remains window-sized and only its origin is moved;
        // resizing/moving a card never refits the global image or tile phase.
        self.plane.setStyleInline(cx.allocator, .{
            .width = .{ .px = cx.viewport.width },
            .height = .{ .px = cx.viewport.height },
            .inset = .{ .left = .{ .px = -rect.x }, .top = .{ .px = -rect.y } },
        });
        // The floor is a leaf: a clipping container's cached own background
        // can replay after its image descendants in the current renderer.
        self.floor.setBackground(floor);
        self.blur.setStyleInline(cx.allocator, .{ .glass = .{ .backdrop_blur = source.blur.style.backdrop_blur(), .capture_current_target = true, .glass_intensity = 0, .specular_opacity = 0, .refraction_level = 0, .warp_gain = 0 }, .background = ui.Color.TRANSPARENT });
        self.blur.setDisplay(source.blur.style.display);
        self.veil.setBackground(source.veil.getBackground());
        self.tint.setBackground(tint);
        self.root.setDisplay(.flex);
        self.fingerprint = fingerprint;
        return true;
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Surface = @ptrCast(@alignCast(raw));
        return if (self.sync() catch false) .needs_layout else .done;
    }

    fn unlink(self: *Surface) void {
        const source = self.source orelse return;
        for (source.surfaces.items, 0..) |surface, index| if (surface == self) {
            _ = source.surfaces.orderedRemove(index);
            break;
        };
        self.source = null;
    }
    /// The target tree may be destroyed before its owning UI scope. The node
    /// callback retires all node borrows while the allocation is still live;
    /// the scope later frees only this independent control/array storage.
    fn rootGone(raw: *anyopaque) void {
        const self: *Surface = @ptrCast(@alignCast(raw));
        self.root_alive = false;
        self.cx.removeAfterLayoutHook(self);
        self.unlink();
    }
    fn cleanup(self: *Surface) void {
        const cx = self.cx;
        cx.removeAfterLayoutHook(self);
        self.unlink();
        if (self.root_alive) {
            // Revoke the node callback before freeing the scope-owned cell.
            self.root.meta.ownership.hooks.on_cleanup = null;
            if (self.root.parent) |parent| parent.removeChild(self.root);
            cx.destroyDetached(self.root);
            self.root_alive = false;
        }
        self.tiles.deinit(cx.allocator);
        cx.allocator.destroy(self);
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

test "background surface releases its node before scope or scope before node exactly once" {
    for ([_]bool{ false, true }) |destroy_target_first| {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        const view_scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        defer view_scope.dispose();
        const surface_scope = try ui.Scope.init(std.testing.allocator, view_scope, cx.owner);
        const root = try ui.box(cx, .{}, .{});
        cx.root = root;
        const view = try View.mount(cx, view_scope);
        try root.appendChild(cx.allocator, view.root);
        const target = try ui.box(cx, .{}, .{});
        try root.appendChild(cx.allocator, target);
        try view.isolate(surface_scope, target);
        try std.testing.expectEqual(@as(usize, 1), view.surfaces.items.len);
        const surface = view.surfaces.items[0];
        if (destroy_target_first) {
            root.removeChild(target);
            cx.destroyDetached(target);
            try std.testing.expect(!surface.root_alive);
            try std.testing.expect(surface.source == null);
            try std.testing.expectEqual(@as(usize, 0), view.surfaces.items.len);
            // A later material refresh must not retain the destroyed target.
            try view.update(null, .{}, 400, 300);
            surface_scope.dispose();
        } else {
            surface_scope.dispose();
            try std.testing.expectEqual(@as(usize, 0), target.children.items.len);
            try std.testing.expectEqual(@as(usize, 0), view.surfaces.items.len);
            root.removeChild(target);
            cx.destroyDetached(target);
        }
    }
}
