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
    group_paints: std.ArrayList(*ui.Node) = .empty,
    fingerprint: ?u64 = null,
    shell_sources: [6]?*ui.Node = @splat(null),
    shell_paints: [6]?*ui.Node = @splat(null),

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
        try cx.addAfterLayoutHook(self, syncShell);
        return self;
    }

    /// Move only the four shell background fills into the canvas tint group.
    /// Foreground nodes keep their geometry, shadows, input and full opacity.
    pub fn bindShell(self: *View, sources: [4]*ui.Node) !void {
        for (sources, 0..) |source, i| try self.bindShellSource(i, source);
    }
    /// Local sessions replace the main status bar with their retained bar.
    pub fn bindLocalStatus(self: *View, source: *ui.Node) !void {
        try self.bindShellSource(4, source);
    }
    /// The AI entry is a fifth visible L0 shape, with foreground dots above it.
    pub fn bindAiEntry(self: *View, source: *ui.Node) !void {
        try self.bindShellSource(5, source);
    }
    fn bindShellSource(self: *View, index: usize, source: *ui.Node) !void {
        self.shell_sources[index] = source;
        source.addBeforeRenderScoped(clearShellFill, .self);
        const fill = try ui.box(self.cx, .{ .position = .absolute, .hit_behavior = .pass_through }, .{});
        fill.meta.ownership.meta.test_id = "appearance.canvas.card";
        try self.veil.appendChild(self.cx.allocator, fill);
        self.shell_paints[index] = fill;
    }
    fn findGroup(node: *ui.Node) ?*ui.Node {
        if (node.isDisplayedInTree() and std.mem.eql(u8, node.meta.ownership.meta.test_id orelse "", "groups.workspace")) return node;
        for (node.children.items) |child| if (findGroup(child)) |found| return found;
        return null;
    }
    fn collectGroupPanes(allocator: std.mem.Allocator, node: *ui.Node, result: *std.ArrayList(*ui.Node)) !void {
        if (std.mem.startsWith(u8, node.meta.ownership.meta.test_id orelse "", "groups.pane.") and !std.mem.eql(u8, node.meta.ownership.meta.test_id orelse "", "groups.pane.header")) {
            try result.append(allocator, node);
            return;
        }
        for (node.children.items) |child| try collectGroupPanes(allocator, child, result);
    }
    fn clearShellFill(node: *ui.Node) void {
        // Retained theme and status hooks may repaint between layout and render.
        if (node.getBackground().a != 0) node.setBackground(ui.Color.TRANSPARENT);
    }
    fn syncShell(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        const origin = self.veil.globalRect();
        var needs_layout = false;
        const workspace = if (self.shell_sources[2]) |pane| findGroup(pane) else null;
        const group = if (workspace) |node| if (node.isDisplayedInTree()) node else null else null;
        var panes: std.ArrayList(*ui.Node) = .empty;
        defer panes.deinit(self.cx.allocator);
        if (group) |node| collectGroupPanes(self.cx.allocator, node, &panes) catch {};
        while (self.group_paints.items.len < panes.items.len) {
            const fill = ui.box(self.cx, .{ .position = .absolute, .hit_behavior = .pass_through }, .{}) catch break;
            self.veil.appendChild(self.cx.allocator, fill) catch break;
            self.group_paints.append(self.cx.allocator, fill) catch break;
        }
        for (self.group_paints.items, 0..) |fill, i| {
            const visible = i < panes.items.len;
            if ((fill.style.display != .none) != visible) {
                fill.setDisplay(if (visible) .flex else .none);
                needs_layout = true;
            }
            if (!visible) continue;
            const rect = panes.items[i].globalRect();
            const old = fill.globalRect();
            if (@abs(old.x - rect.x) > 0.01 or @abs(old.y - rect.y) > 0.01 or @abs(old.w - rect.w) > 0.01 or @abs(old.h - rect.h) > 0.01) {
                fill.setStyleInline(self.cx.allocator, .{ .width = .{ .px = rect.w }, .height = .{ .px = rect.h }, .inset = .{ .left = .{ .px = rect.x - origin.x }, .top = .{ .px = rect.y - origin.y } }, .border = .{ .radius = 11 } });
                needs_layout = true;
            }
            fill.setBackground(theme.baseColors().surface_1.withAlpha(255));
        }
        for (self.shell_sources, self.shell_paints, 0..) |maybe, paint_maybe, index| {
            const source = maybe orelse continue;
            const fill = paint_maybe.?;
            const rect = source.globalRect();
            var visible = rect.w > 0 and rect.h > 0 and !(index == 2 and group != null);
            var ancestor: ?*ui.Node = source;
            while (ancestor) |node| : (ancestor = node.parent) {
                if (node.style.display == .none) visible = false;
            }
            if ((fill.style.display != .none) != visible) {
                fill.setDisplay(if (visible) .flex else .none);
                needs_layout = true;
            }
            // Hidden replacements (e.g. the main status bar while a local
            // terminal is active) keep their last source rect, but their
            // hidden fill is not laid out. Comparing those forever would
            // request a new layout and frame even in a completely idle window.
            if (!visible) continue;
            const old = fill.globalRect();
            if (@abs(old.x - rect.x) > 0.01 or @abs(old.y - rect.y) > 0.01 or @abs(old.w - rect.w) > 0.01 or @abs(old.h - rect.h) > 0.01) {
                needs_layout = true;
                fill.setStyleInline(self.cx.allocator, .{ .width = .{ .px = rect.w }, .height = .{ .px = rect.h }, .inset = .{ .left = .{ .px = rect.x - origin.x }, .top = .{ .px = rect.y - origin.y } } });
            }
            const color = theme.baseColors().surface_1.withAlpha(255);
            if (!ui.Color.eql(fill.getBackground(), color)) fill.setBackground(color);
            if (fill.style.effectiveRadius() != source.style.effectiveRadius()) fill.setStyle(self.cx.allocator, .corner_radius, .{ .all = source.style.effectiveRadius() });
            if (source.getBackground().a != 0) source.setBackground(ui.Color.TRANSPARENT);
        }
        return if (needs_layout) .needs_layout else .done;
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
        @import("floating_input.zig").protect(self.cx, target);
        try scope.createEffect(.{ .cx = self.cx, .target = target, .publication = try self.cx.themeSignal(scope) }, struct {
            fn paint(ctx: anytype) void {
                _ = ctx.publication.get();
                ctx.target.setStyleInline(ctx.cx.allocator, theme.overlayPaint());
            }
        }.paint);
    }

    fn paint(self: *View, texture: ?Image, materials: material.Materials, width: f32, height: f32) !void {
        try materials.validate();
        const background = materials.background;
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, .{ if (texture) |image| image.id else @as(u32, 0), if (texture) |image| image.width else @as(u32, 0), if (texture) |image| image.height else @as(u32, 0), if (texture) |image| image.repeating else null, background.enabled, @as(u32, @bitCast(width)), @as(u32, @bitCast(height)), background.fit, background.alignment_x, background.alignment_y, @as(u32, @bitCast(background.transparency)), materials.blur_px, theme.baseColors().app });
        const fingerprint = hash.final();
        if (self.fingerprint == fingerprint) return;
        // Apply the one canvas alpha only when effective material changes.
        self.veil.setStyleInline(self.cx.allocator, .{ .composited_group = true, .opacity = 1 - background.alpha(), .background = theme.baseColors().app.withAlpha(255) });
        if (!background.enabled or texture == null) {
            self.root.setBackground(theme.baseColors().app);
            self.root.setDisplay(.flex);
            self.images.setDisplay(.none);
            self.blur.setDisplay(.none);
            self.veil.setDisplay(.flex);
            self.fingerprint = fingerprint;
            return;
        }
        const image = texture.?;
        const transform = try geometry.resolve(.{ .source = .{ .pixel_width = image.width, .pixel_height = image.height }, .window = .{ .width = width, .height = height }, .fit = background.fit, .horizontal = background.alignment_x, .vertical = background.alignment_y });
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
        // Preview surfaces are composited offscreen. Sample their own image,
        // not the settings/terminal pixels behind the preview's surface.
        self.blur.setStyleInline(self.cx.allocator, .{ .glass = .{ .backdrop_blur = @floatFromInt(materials.blur_px), .glass_intensity = 0, .specular_opacity = 0, .refraction_level = 0, .warp_gain = 0, .capture_current_target = true, .capture_clamp = true, .a11y_exempt = true }, .background = ui.Color.TRANSPARENT });
        self.blur.setDisplay(if (materials.blur_px == 0) .none else .flex);
        // Only this background group is translucent; image blur is shared once.
        self.root.setDisplay(.flex);
        self.fingerprint = fingerprint;
        self.cx.requestRedraw();
    }
    fn layer() ui.BoxStyle {
        return .{ .hit_behavior = .pass_through, .hit_roles = .{ .pointer = false, .scroll = false, .inspect = false }, .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .right = .{ .px = 0 }, .top = .{ .px = 0 }, .bottom = .{ .px = 0 } }, .width = .fill(), .height = .fill() };
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        self.group_paints.deinit(self.cx.allocator);
        self.tiles.deinit(self.cx.allocator);
        self.cx.allocator.destroy(self);
    }
};

test "material hidden shell replacement settles without repeated layout requests" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(800, 600);
    const view = try View.mount(cx, scope);
    cx.root = view.root;
    try view.update(null, .{}, 800, 600);
    const source = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 5 }, .top = .{ .px = 550 } }, .width = .{ .px = 790 }, .height = .{ .px = 26 } }, .{});
    try cx.root.?.appendChild(cx.allocator, source);
    try view.bindLocalStatus(source);
    _ = cx.render();
    source.setDisplay(.none);
    for (0..2) |_| {
        cx.frame_count += 1;
        cx.frame_time_ms += 16;
        _ = cx.render();
    }
    for (0..3) |_| try std.testing.expectEqual(ui.AfterLayoutResult.done, View.syncShell(view, 0, false));
    source.setDisplay(.flex);
    for (0..2) |_| {
        cx.frame_count += 1;
        cx.frame_time_ms += 16;
        _ = cx.render();
    }
    try std.testing.expectEqual(.flex, view.shell_paints[4].?.style.display);
    try std.testing.expectEqual(source.globalRect().w, view.shell_paints[4].?.globalRect().w);
}

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

test "global material composites opaque shell fills before applying canvas transparency once" {
    const parameters = theme.materialParameters();
    defer _ = theme.setMaterialParameters(parameters.transparency, parameters.blur);
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
    var sources: [4]*ui.Node = undefined;
    for (&sources, 0..) |*source, i| {
        source.* = try ui.box(cx, .{ .position = .absolute, .width = .{ .px = 200 }, .height = .{ .px = 50 }, .inset = .{ .left = .{ .px = 5 }, .top = .{ .px = @floatFromInt(5 + i * 60) } }, .background = theme.baseColors().surface_1.withAlpha(255), .border = .{ .radius = 11 } }, .{});
        try view.root.appendChild(cx.allocator, source.*);
    }
    try view.bindShell(sources);
    const entry = try ui.box(cx, @import("ai_strip_styles.zig").lip(theme.widgetTheme(theme.currentName())), .{});
    try view.root.appendChild(cx.allocator, entry);
    try view.bindAiEntry(entry);
    var materials: material.Materials = .{ .background = .{ .enabled = true, .path = "/fixture", .fit = .fit } };
    for (std.enums.values(theme.Name)) |name| {
        theme.select(name);
        for ([_]f32{ 0, 50, 100 }) |percent| {
            materials.background.transparency = percent;
            materials.blur_px = @intFromFloat(percent * 0.96);
            _ = theme.setMaterialParameters(percent, @floatFromInt(materials.blur_px));
            try view.update(.{ .id = 7, .width = 320, .height = 180 }, materials, 1440, 900);
            cx.layout();
            _ = View.syncShell(view, 0, false);
            cx.layout();
            try std.testing.expectEqual(1 - percent / 100, view.veil.getOpacity());
            try std.testing.expect(view.veil.style.composited_group());
            try std.testing.expectEqual(@as(u8, 0), entry.getBackground().a);
            try std.testing.expectEqual(@as(f32, 0), entry.style.backdrop_blur());
            try std.testing.expectEqual(@as(u8, 255), view.shell_paints[5].?.getBackground().a);
            try std.testing.expect(view.shell_paints[5].?.parent == view.veil);
            for (sources, view.shell_paints[0..4]) |source, paint| {
                try std.testing.expectEqual(@as(u8, 0), source.getBackground().a);
                try std.testing.expectEqual(@as(u8, 255), paint.?.getBackground().a);
            }
            try std.testing.expectEqual(@as(f32, @floatFromInt(materials.blur_px)), view.blur.style.backdrop_blur());
            try std.testing.expect((view.blur.style.display == .none) == (materials.blur_px == 0));
            cx.layout();
            try std.testing.expectEqual(@as(u8, 0), theme.current().app.a);
            try std.testing.expectEqual(theme.baseColors().app, view.root.getBackground());
            try std.testing.expectEqual(theme.baseColors().app.withAlpha(255), view.veil.getBackground());
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
        try std.testing.expectEqual(@max(12, blur), popup.style.backdrop_blur());
    }
}

test "group canvas paints each member and leaves gutters on base canvas" {
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const view = try View.mount(cx, scope);
    cx.root = view.root;
    cx.setViewport(800, 600);
    try view.update(null, .{}, 800, 600);
    var sources: [4]*ui.Node = undefined;
    for (&sources) |*source| {
        source.* = try ui.box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
        try view.root.appendChild(a, source.*);
    }
    try view.bindShell(sources);
    const group = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .row, .gap = 4 }, .{});
    group.meta.ownership.meta.test_id = "groups.workspace";
    try sources[2].appendChild(a, group);
    for (0..2) |i| {
        const pane = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .flex = 1, .border = .{ .radius = 11 } }, .{});
        pane.meta.ownership.meta.test_id = if (i == 0) "groups.pane.1" else "groups.pane.2";
        try group.appendChild(a, pane);
    }
    for (0..3) |_| {
        cx.layout();
        _ = View.syncShell(view, 0, false);
    }
    cx.layout();
    try std.testing.expectEqual(@as(usize, 2), view.group_paints.items.len);
    try std.testing.expectEqual(.none, view.shell_paints[2].?.style.display);
    const first = view.group_paints.items[0].globalRect();
    const second = view.group_paints.items[1].globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 4), second.x - first.x - first.w, 0.01);
    for (view.group_paints.items) |paint| {
        try std.testing.expect(paint.parent == view.veil);
        try std.testing.expectEqual(@as(u8, 255), paint.getBackground().a);
        try std.testing.expectEqual(@as(f32, 11), paint.style.effectiveRadius());
    }
    group.setDisplay(.none);
    for (0..2) |_| {
        cx.layout();
        _ = View.syncShell(view, 0, false);
    }
    try std.testing.expectEqual(.flex, view.shell_paints[2].?.style.display);
    for (view.group_paints.items) |paint| try std.testing.expectEqual(.none, paint.style.display);
}
