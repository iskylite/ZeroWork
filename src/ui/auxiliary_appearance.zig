//! Window-owned projection of the application's global appearance. CPU assets
//! are borrowed only during upload; a texture handle never crosses renderers.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const assets = @import("../config/background_asset.zig");
const layers = @import("background_layers.zig");
const textures = @import("background_texture.zig");
const theme = @import("app_theme.zig");
const ThemePublication = @import("shell_styles.zig").ThemePublication;

pub const Change = struct {
    theme_changed: bool = false,
    material_changed: bool = false,
    /// Report once per failed source. The last successful texture stays owned.
    problem: ?anyerror = null,
};

const TextureOperations = struct {
    context: ?*anyopaque = null,
    upload: *const fn (?*anyopaque, *App, *const assets.Prepared) anyerror!textures.Texture = struct {
        fn run(_: ?*anyopaque, app: *App, source: *const assets.Prepared) !textures.Texture {
            return textures.upload(app, source);
        }
    }.run,
    release: *const fn (?*anyopaque, *textures.Texture) void = struct {
        fn run(_: ?*anyopaque, texture: *textures.Texture) void {
            texture.deinit();
        }
    }.run,
};

pub const Appearance = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    view: *layers.View,
    publication: *ThemePublication,
    app: ?*App = null,
    texture: ?textures.Texture = null,
    source_key: ?u64 = null,
    failed_source_key: ?u64 = null,
    materials: assets.Materials = .{},
    material_path: ?[]u8 = null,
    image_visible: bool = false,
    theme_published: bool = false,
    colors: ?theme.Colors = null,
    operations: TextureOperations = .{},

    /// Mount below this window's user tree and overlay portal. App.mount has
    /// installed its runtime root before invoking the user's mount callback.
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope) !*Appearance {
        const parent = cx.root orelse return error.WindowRootUnavailable;
        const root = try ui.box(cx, .{
            .position = .absolute,
            .inset = .{ .left = .{ .px = 0 }, .right = .{ .px = 0 }, .top = .{ .px = 0 }, .bottom = .{ .px = 0 } },
            .width = .fill(),
            .height = .fill(),
            .background = theme.baseColors().app.withAlpha(255),
            .overflow = .hidden,
        }, .{});
        errdefer cx.destroyDetached(root);
        root.meta.ownership.meta.test_id = "appearance.auxiliary";
        const view = try layers.View.mount(cx, scope);
        try root.appendChild(cx.allocator, view.root);
        const self = try scope.createState(Appearance, .{ .cx = cx, .root = root, .view = view, .publication = try cx.bindState(ThemePublication, .{}) });
        try scope.onCleanup(Appearance, self, cleanup);
        try cx.addAfterLayoutHook(self, afterLayout);
        try @import("layer_materials.zig").Policy.mount(cx, scope);
        try parent.insertChildBefore(cx.allocator, root, if (parent.children.items.len > 0) parent.children.items[0] else null);
        return self;
    }

    /// Call on the UI thread after createWindowWith returns its actual App.
    /// source_revision identifies the caller's effective saved/preview image;
    /// Prepared's draft/revision/path are also included in admission identity.
    /// Pass global app_theme.widgetTheme tokens, whose names are process-owned.
    pub fn refresh(self: *Appearance, app: *App, source: ?*const assets.Prepared, materials: assets.Materials, source_revision: u64, tokens: *const ui.ThemeTokens) !Change {
        if (app.cx != self.cx or (self.app != null and self.app.? != app)) return error.WrongWindow;
        try materials.validate();
        try self.copyMaterials(materials);
        self.app = app;
        var change: Change = .{};
        const colors = theme.current();
        if (!self.theme_published or !std.meta.eql(self.publication.snapshots[self.publication.slot], tokens.*) or self.colors == null or !std.meta.eql(self.colors.?, colors)) {
            self.publication.publish(self.cx, tokens);
            self.theme_published = true;
            self.colors = colors;
            change.theme_changed = true;
        }
        const old_base = self.root.getBackground();
        self.root.setBackground(theme.baseColors().app.withAlpha(255));
        change.material_changed = !ui.Color.eql(old_base, self.root.getBackground());
        self.image_visible = materials.background.enabled and source != null;
        if (self.image_visible) {
            const prepared = source.?;
            const key = sourceKey(prepared, source_revision);
            if (self.source_key != key and self.failed_source_key != key) {
                if (!std.mem.eql(u8, prepared.path, materials.background.path)) {
                    self.failed_source_key = key;
                    change.problem = error.BackgroundSourceMismatch;
                } else {
                    const uploaded = self.operations.upload(self.operations.context, app, prepared) catch |err| failed: {
                        self.failed_source_key = key;
                        change.problem = err;
                        break :failed null;
                    };
                    if (uploaded) |texture| {
                        if (self.texture) |*previous| self.operations.release(self.operations.context, previous);
                        self.texture = texture;
                        self.source_key = key;
                        self.failed_source_key = null;
                        change.material_changed = true;
                    }
                }
            }
        }
        change.material_changed = try self.paint() or change.material_changed;
        if (change.theme_changed or change.material_changed) self.cx.requestRedraw();
        return change;
    }

    /// An explicit user retry or restored renderer can reopen admission for
    /// the same failed source; ordinary redraws never repeat that upload.
    pub fn retry(self: *Appearance) void {
        self.failed_source_key = null;
        self.cx.requestRedraw();
    }

    fn sourceKey(source: *const assets.Prepared, revision: u64) u64 {
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, .{ revision, source.draft_id, source.asset_revision, source.image.width, source.image.height });
        hash.update(source.path);
        return hash.final();
    }
    fn copyMaterials(self: *Appearance, materials: assets.Materials) !void {
        if (self.material_path == null or !std.mem.eql(u8, self.material_path.?, materials.background.path)) {
            const path = try self.cx.allocator.dupe(u8, materials.background.path);
            if (self.material_path) |previous| self.cx.allocator.free(previous);
            self.material_path = path;
        }
        self.materials = materials;
        self.materials.background.path = self.material_path.?;
    }
    fn paint(self: *Appearance) !bool {
        const before = self.view.fingerprint;
        const image: ?layers.Image = if (self.image_visible) if (self.texture) |value| .{ .id = value.id, .width = value.width, .height = value.height, .repeating = value.repeating } else null else null;
        try self.view.update(image, self.materials, self.cx.viewport.width, self.cx.viewport.height);
        return before != self.view.fingerprint;
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Appearance = @ptrCast(@alignCast(raw));
        // Geometry is local even when the primary window is idle/minimized.
        return if (self.paint() catch false) .needs_layout else .done;
    }
    fn cleanup(self: *Appearance) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.texture) |*texture| self.operations.release(self.operations.context, texture);
        self.texture = null;
        self.app = null;
        if (self.material_path) |path| self.cx.allocator.free(path);
        self.material_path = null;
    }
};

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) !*Appearance {
    return Appearance.mount(cx, scope);
}

test "auxiliary appearance owns window textures and copies material path for local resize" {
    const h = try TestWindow.init();
    defer h.deinit();
    var app: App = undefined;
    app.cx = h.cx;
    var spy: TestTextures = .{};
    const appearance = try mount(h.cx, h.scope);
    appearance.operations = spy.operations();
    var asset = try testAsset(3, 4, "/prepared.png");
    const materials: assets.Materials = .{ .background = .{ .enabled = true, .path = asset.path, .fit = .fit, .transparency = 50 }, .blur_px = 12 };
    const first = try appearance.refresh(&app, &asset, materials, 8, theme.widgetTheme(theme.currentName()));
    try std.testing.expect(first.theme_changed and first.material_changed and first.problem == null);
    try std.testing.expectEqual(@as(usize, 1), spy.uploads);
    const again = try appearance.refresh(&app, &asset, materials, 8, theme.widgetTheme(theme.currentName()));
    try std.testing.expect(!again.theme_changed and !again.material_changed);
    asset.deinit(std.testing.allocator);
    h.cx.setViewport(600, 500);
    _ = h.cx.render();
    _ = h.cx.render();
    try std.testing.expectEqualStrings("/prepared.png", appearance.materials.background.path);
    const rect = appearance.view.tiles.items[0].globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 600), rect.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 300), rect.h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 100), rect.y, 0.1);
    try std.testing.expectEqual(@as(usize, 1), spy.uploads);
    try std.testing.expectEqual(@as(f32, 12), appearance.view.blur.style.backdrop_blur());
    try std.testing.expectEqual(theme.baseColors().app.withAlpha(128), appearance.view.veil.getBackground());
}

test "auxiliary appearance retains last texture and reports a failed revision once until retry" {
    const h = try TestWindow.init();
    defer h.deinit();
    var app: App = undefined;
    app.cx = h.cx;
    var spy: TestTextures = .{};
    const appearance = try mount(h.cx, h.scope);
    appearance.operations = spy.operations();
    var asset = try testAsset(1, 1, "/prepared.png");
    defer asset.deinit(std.testing.allocator);
    const materials: assets.Materials = .{ .background = .{ .enabled = true, .path = asset.path } };
    _ = try appearance.refresh(&app, &asset, materials, 1, theme.widgetTheme(theme.currentName()));
    const old_id = appearance.texture.?.id;
    spy.reject = true;
    const rejected = try appearance.refresh(&app, &asset, materials, 2, theme.widgetTheme(theme.currentName()));
    try std.testing.expectEqual(error.TextureAllocationFailed, rejected.problem.?);
    try std.testing.expectEqual(old_id, appearance.texture.?.id);
    try std.testing.expectEqual(@as(usize, 0), spy.releases);
    for (0..3) |_| {
        const repeated = try appearance.refresh(&app, &asset, materials, 2, theme.widgetTheme(theme.currentName()));
        try std.testing.expect(repeated.problem == null);
    }
    try std.testing.expectEqual(@as(usize, 2), spy.uploads);
    spy.reject = false;
    appearance.retry();
    const recovered = try appearance.refresh(&app, &asset, materials, 2, theme.widgetTheme(theme.currentName()));
    try std.testing.expect(recovered.problem == null and recovered.material_changed);
    try std.testing.expectEqual(@as(usize, 3), spy.uploads);
    try std.testing.expectEqual(@as(usize, 1), spy.releases);
    try std.testing.expectEqual(@as(?*App, &app), spy.last_release_app);
}

test "auxiliary appearance rejects another Cx and republishes retained global token addresses" {
    const previous_name = theme.currentName();
    const previous_material = theme.materialVisible();
    defer {
        theme.select(previous_name);
        _ = theme.setMaterialVisible(previous_material);
    }
    theme.select(.light);
    const first = try TestWindow.init();
    defer first.deinit();
    const second = try TestWindow.init();
    defer second.deinit();
    var first_app: App = undefined;
    first_app.cx = first.cx;
    var second_app: App = undefined;
    second_app.cx = second.cx;
    const appearance = try mount(first.cx, first.scope);
    try std.testing.expectError(error.WrongWindow, appearance.refresh(&second_app, null, .{}, 0, theme.widgetTheme(theme.currentName())));
    _ = theme.setMaterialVisible(true);
    const tokens = theme.widgetTheme(theme.currentName());
    const initial = try appearance.refresh(&first_app, null, .{}, 0, tokens);
    try std.testing.expect(initial.theme_changed);
    const version = first.cx.theme_version;
    const retained = tokens.*;
    theme.select(.dark);
    try std.testing.expectEqualDeep(retained, tokens.*);
    const changed = try appearance.refresh(&first_app, null, .{}, 0, theme.widgetTheme(theme.currentName()));
    try std.testing.expect(changed.theme_changed);
    try std.testing.expect(first.cx.theme_version > version);
    try std.testing.expectEqual(theme.baseColors().app.withAlpha(255), appearance.root.getBackground());
    try std.testing.expectEqual(.flex, appearance.view.root.style.display);
    try std.testing.expect(theme.materialVisible());
}

const TestWindow = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    fn init() !TestWindow {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(840, 578);
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        return .{ .cx = cx, .scope = scope };
    }
    fn deinit(self: TestWindow) void {
        self.scope.dispose();
        self.cx.deinit();
    }
};
const TestTextures = struct {
    uploads: usize = 0,
    releases: usize = 0,
    reject: bool = false,
    last_release_app: ?*App = null,
    fn operations(self: *TestTextures) TextureOperations {
        return .{ .context = self, .upload = upload, .release = release };
    }
    fn upload(raw: ?*anyopaque, app: *App, source: *const assets.Prepared) !textures.Texture {
        const self: *TestTextures = @ptrCast(@alignCast(raw.?));
        self.uploads += 1;
        if (self.reject) return error.TextureAllocationFailed;
        return .{ .app = app, .id = @intCast(self.uploads + 100), .width = source.image.width, .height = source.image.height };
    }
    fn release(raw: ?*anyopaque, texture: *textures.Texture) void {
        const self: *TestTextures = @ptrCast(@alignCast(raw.?));
        self.releases += 1;
        self.last_release_app = texture.app;
        texture.* = undefined;
    }
};
fn testAsset(draft_id: u64, revision: u64, path: []const u8) !assets.Prepared {
    const a = std.testing.allocator;
    const owned_path = try a.dupe(u8, path);
    errdefer a.free(owned_path);
    return .{ .draft_id = draft_id, .asset_revision = revision, .path = owned_path, .image = .{ .width = 2, .height = 1, .pixels = try a.dupe(u8, &.{ 0, 0, 0, 255, 255, 255, 255, 255 }) } };
}
