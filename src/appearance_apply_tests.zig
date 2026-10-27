//! Transaction tests use explicit prepared metrics; real platform font
//! resolution and raster decoding have separate no-window tests.
const std = @import("std");
const appearance = @import("config/appearance_apply.zig");
const runtime = @import("config/runtime_config.zig");
const settings = @import("config/settings_controller.zig");
const themes = @import("config/theme_registry.zig");
const material = @import("config/background_asset.zig");

fn metrics(size: f32) appearance.Typography {
    return .{ .requested_family = "Monaco", .actual_family = "Menlo", .size = size, .weight = 400, .family_id = 1, .cell_width = 8.4, .ascent = 12, .descent = 3, .fallback = true };
}

fn testAsset(draft_id: u64, revision: u64, path: []const u8) !material.Prepared {
    const allocator = std.testing.allocator;
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    return .{ .draft_id = draft_id, .asset_revision = revision, .path = owned_path, .image = .{ .width = 1, .height = 1, .pixels = try allocator.dupe(u8, &.{ 255, 0, 0, 255 }) } };
}

test "appearance publishes revisions once after shared Save and merges an immediate global theme" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer target.deinit();
    var registry = try themes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var draft = try settings.Controller.init(std.testing.allocator, target.value);
    defer draft.deinit();
    var state: appearance.State = .{ .allocator = std.testing.allocator };
    defer state.deinit();
    try draft.editKey("ui", "font_size", .{ .unsigned = 18 });
    var immediate_value = target.value;
    immediate_value.ui.theme = "light";
    var immediate = try target.prepare(immediate_value);
    defer immediate.deinit();
    var preview = try appearance.prepare(std.testing.allocator, &registry, &immediate, null, metrics(14), null, null);
    defer preview.deinit();
    try std.testing.expect(state.snapshot == null);
    try std.testing.expectApproxEqAbs(@as(f32, 21), preview.layout.line_pixels, 0.00001);
    try state.commit(std.testing.io, tmp.dir, &registry, &target, &immediate, &preview, null);
    const theme_revision = state.theme_revision;
    const material_revision = state.material_revision;
    var save = try draft.beginSave(&target, false);
    defer save.deinit();
    var prepared = try appearance.prepare(std.testing.allocator, &registry, &save.prepared, &state, metrics(18), null, null);
    defer prepared.deinit();
    try std.testing.expect(try state.completeSettings(std.testing.io, tmp.dir, &registry, &draft, &target, &save, &prepared, null));
    try std.testing.expectEqualStrings("light", target.value.ui.theme);
    try std.testing.expectEqual(@as(u8, 18), target.value.ui.font_size);
    try std.testing.expectEqual(theme_revision, state.theme_revision);
    try std.testing.expectEqual(material_revision, state.material_revision);
    try std.testing.expectEqual(target.value.config_revision, state.layout_revision);
    try std.testing.expectEqualStrings("Menlo", state.layout.?.font.actual_family);
    try std.testing.expect(state.layout.?.font.fallback);
    try std.testing.expect(!try state.completeSettings(std.testing.io, tmp.dir, &registry, &draft, &target, &save, &prepared, null));
    try draft.editKey("ui.materials", "blur_px", .{ .unsigned = 24 });
    try draft.discardLatest(&target);
    try std.testing.expectEqualStrings("light", draft.model.value.ui.theme);
    try std.testing.expect(!draft.model.dirty);
}

test "appearance Save disk failure retains draft resources and does not publish" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "blocked/config.toml");
    defer target.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocked", .data = "file" });
    var registry = try themes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var draft = try settings.Controller.init(std.testing.allocator, target.value);
    defer draft.deinit();
    try draft.editKey("ui", "theme", .{ .text = "dracula" });
    var save = try draft.beginSave(&target, false);
    defer save.deinit();
    var state: appearance.State = .{ .allocator = std.testing.allocator };
    defer state.deinit();
    var prepared = try appearance.prepare(std.testing.allocator, &registry, &save.prepared, null, metrics(14), null, null);
    defer prepared.deinit();
    try std.testing.expectError(error.NotDir, state.completeSettings(std.testing.io, tmp.dir, &registry, &draft, &target, &save, &prepared, null));
    try std.testing.expect(state.snapshot == null);
    try std.testing.expect(prepared.snapshot != null);
    try std.testing.expectEqualStrings("dark", target.value.ui.theme);
    try std.testing.expectEqualStrings("dracula", draft.model.value.ui.theme);
    try std.testing.expect(draft.canSave());
}

test "appearance image preflight failure and enabled unprepared assets cannot commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer target.deinit();
    var registry = try themes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var candidate = target.value;
    candidate.ui.materials.background = .{ .enabled = true, .path = "/worker-prepared.png", .transparency = 12 };
    var prepared = try target.prepare(candidate);
    defer prepared.deinit();
    try std.testing.expectError(error.BackgroundNotPrepared, target.commitPrepared(std.testing.io, tmp.dir, &prepared));
    var asset = try testAsset(1, 2, candidate.ui.materials.background.path);
    defer asset.deinit(std.testing.allocator);
    const Reject = struct {
        fn check(_: *anyopaque, _: *const material.Prepared) !void {
            return error.TextureAllocationFailed;
        }
    };
    var context: u8 = 0;
    try std.testing.expectError(error.TextureAllocationFailed, appearance.prepare(std.testing.allocator, &registry, &prepared, null, metrics(14), &asset, .{ .context = &context, .check = Reject.check }));
    try std.testing.expectEqual(@as(usize, 4), asset.image.pixels.len);
    try std.testing.expect(!prepared.background_ready);
    try std.testing.expect(!target.value.ui.materials.background.enabled);
}

test "appearance prepared image and config publish together and keep image alpha separate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer target.deinit();
    var registry = try themes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var candidate = target.value;
    candidate.ui.materials = .{ .blur_px = 24, .background = .{ .enabled = true, .path = "/worker-prepared.png", .transparency = 12 } };
    var prepared = try target.prepare(candidate);
    defer prepared.deinit();
    var asset = try testAsset(1, 2, candidate.ui.materials.background.path);
    var asset_owned = true;
    defer if (asset_owned) asset.deinit(std.testing.allocator);
    var projection = try appearance.prepare(std.testing.allocator, &registry, &prepared, null, metrics(14), &asset, null);
    asset_owned = false;
    defer projection.deinit();
    var state: appearance.State = .{ .allocator = std.testing.allocator };
    defer state.deinit();
    try state.commit(std.testing.io, tmp.dir, &registry, &target, &prepared, &projection, null);
    try std.testing.expect(target.background_ready);
    try std.testing.expect(target.value.ui.materials.background.enabled);
    try std.testing.expectEqualStrings(target.value.ui.materials.background.path, state.asset.?.path);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, state.asset.?.image.pixels);
    try std.testing.expectApproxEqAbs(@as(f32, 0.88), state.snapshot.?.value.ui.materials.background.alpha(), 0.000001);
    try std.testing.expectEqual(target.value.config_revision, state.material_revision);
}

test "background controller retains old identity on failure rejects late callbacks and restores only materials" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer target.deinit();
    var draft = try settings.Controller.init(std.testing.allocator, target.value);
    defer draft.deinit();
    try draft.editKey("ui.materials.background", "enabled", .{ .boolean = true });
    try std.testing.expect(!draft.canSave());
    var request = try draft.requestBackground("/good.png");
    defer request.deinit();
    var prepared = try testAsset(request.request.draft_id, request.request.asset_revision, request.request.path);
    try std.testing.expect(try draft.completeBackground(&prepared));
    try std.testing.expect(draft.canSave());
    var failed = try draft.requestBackground("/missing.png");
    defer failed.deinit();
    try std.testing.expect(draft.failBackground(failed.request, error.FileNotFound));
    try std.testing.expectEqualStrings("/good.png", draft.model.value.ui.materials.background.path);
    try std.testing.expect(!draft.canSave());
    try draft.editKey("ui.materials.background", "enabled", .{ .boolean = false });
    try draft.editRaw("ui", "font_size", "19");
    try std.testing.expectError(error.OutOfRange, draft.editRaw("ui.materials", "blur_px", "97"));
    try std.testing.expectEqual(@as(u8, 0), draft.model.value.ui.materials.blur_px);
    try std.testing.expectEqualStrings("97", draft.raw_fields[runtime.schema.find("ui.materials", "blur_px").?].input.?);
    try std.testing.expect(!draft.canSave());
    try draft.restoreMaterials(&target);
    try std.testing.expectEqual(@as(u8, 19), draft.model.value.ui.font_size);
    try std.testing.expectEqualStrings("19", draft.raw_fields[runtime.schema.find("ui", "font_size").?].input.?);
    try std.testing.expect(draft.raw_fields[runtime.schema.find("ui.materials", "blur_px").?].input == null);
    try std.testing.expectEqualDeep(target.value.ui.materials, draft.model.value.ui.materials);
    var late = try testAsset(request.request.draft_id, request.request.asset_revision, request.request.path);
    try std.testing.expect(!try draft.completeBackground(&late));
    try std.testing.expect(draft.canSave());
    try draft.editKey("ui.materials.background", "path", .{ .text = "/missing.png" });
    try draft.save(std.testing.io, tmp.dir, &target);
    try std.testing.expectEqualStrings("/missing.png", target.value.ui.materials.background.path);
    try std.testing.expect(!target.value.ui.materials.background.enabled);
}

test "appearance materials preserve precise defaults escaped path axes and fractional transparency" {
    const config = @import("config/config.zig");
    const store = @import("config/store.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var value: config.Config = .{};
    try std.testing.expectEqualStrings("dark", value.ui.theme);
    try std.testing.expectEqualStrings("Monaco", value.ui.font_family);
    try std.testing.expectEqual(@as(u8, 14), value.ui.font_size);
    try std.testing.expectEqual(@as(f32, 1.5), value.ui.line_height);
    try std.testing.expectEqualStrings("sauber", config.resetDefaults().ui.theme);
    value.ui.materials = .{ .blur_px = 96, .background = .{ .path = "/tmp/图;#\"\\\n.png", .fit = .tile, .alignment_x = .right, .alignment_y = .bottom, .transparency = 12.5 } };
    try store.save(std.testing.io, tmp.dir, "config.toml", value);
    var loaded = try store.load(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(value.ui.materials, loaded.value.ui.materials);
    try std.testing.expectEqual(value.ui.line_height, loaded.value.ui.line_height);
    try std.testing.expectApproxEqAbs(@as(f32, 21), @as(f32, 14) * loaded.value.ui.line_height, 0.00001);
}

fn themeSource() ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(std.testing.allocator);
    for (0..19) |i| {
        var key_buffer: [32]u8 = undefined;
        const key = if (i < 16) try std.fmt.bufPrint(&key_buffer, "Ansi {d} Color", .{i}) else ([_][]const u8{ "Background Color", "Foreground Color", "Cursor Color" })[i - 16];
        const entry = try std.fmt.allocPrint(std.testing.allocator, "<key>{s}</key><dict><key>Red Component</key><real>0.25</real><key>Green Component</key><real>0</real><key>Blue Component</key><real>0</real></dict>", .{key});
        defer std.testing.allocator.free(entry);
        try source.appendSlice(std.testing.allocator, entry);
    }
    return source.toOwnedSlice(std.testing.allocator);
}

test "appearance library retains query selection and draft identity across cancel stale import and Discard" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer target.deinit();
    var registry = try themes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var draft = try settings.Controller.init(std.testing.allocator, target.value);
    defer draft.deinit();
    var query = [_]u8{ 'D', 'R' };
    try draft.theme_library.setQuery(std.testing.allocator, &query);
    @memset(&query, 'x');
    draft.theme_library.filter = .imported;
    draft.theme_library.scroll = 48;
    try draft.selectTheme(&registry, "dracula");
    try std.testing.expectEqualStrings("DR", draft.theme_library.query);
    try std.testing.expectEqualStrings("dracula", draft.theme_library.selected_id);
    const cancelled = try draft.requestThemeImport();
    draft.cancelThemeImport(cancelled);
    try std.testing.expectEqual(@as(usize, 0), registry.counts().imported);
    const first = try draft.requestThemeImport();
    const second = try draft.requestThemeImport();
    const source = try themeSource();
    defer std.testing.allocator.free(source);
    var old = try themes.Registry.parseImport(std.testing.allocator, first, source, "Old");
    try std.testing.expect(!try draft.completeThemeImport(&registry, &old));
    try std.testing.expectEqualStrings("dracula", draft.model.value.ui.theme);
    var current = try themes.Registry.parseImport(std.testing.allocator, second, source, "Imported");
    try std.testing.expect(try draft.completeThemeImport(&registry, &current));
    try std.testing.expect(std.mem.startsWith(u8, draft.model.value.ui.theme, "import:"));
    try std.testing.expectEqualStrings(draft.model.value.ui.theme, draft.theme_library.selected_id);
    try registry.favorite(std.testing.io, tmp.dir, "themes/favorites.json", "dark", registry.revision, true);
    try draft.discardLatest(&target);
    registry.discard(draft.draft_id);
    try std.testing.expectEqual(@as(usize, 0), registry.counts().imported);
    try std.testing.expect(registry.get("dark").?.favorite);
    try std.testing.expectEqualStrings("dark", draft.theme_library.selected_id);
    try std.testing.expectEqualStrings("DR", draft.theme_library.query);
    try std.testing.expectEqual(themes.Filter.imported, draft.theme_library.filter);
    try std.testing.expectEqual(@as(f32, 48), draft.theme_library.scroll);
    try std.testing.expect(!draft.model.dirty);
}

test "appearance staged import requires worker installation before atomic configuration and publish" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer target.deinit();
    var registry = try themes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const request: themes.ImportRequest = .{ .draft_id = 81, .operation_id = 1 };
    const source = try themeSource();
    defer std.testing.allocator.free(source);
    var result = try themes.Registry.parseImport(std.testing.allocator, request, source, "Worker import");
    const id = (try registry.completeImport(request, &result)).?;
    var candidate = target.value;
    candidate.ui.theme = id;
    var prepared = try target.prepare(candidate);
    defer prepared.deinit();
    var projection = try appearance.prepare(std.testing.allocator, &registry, &prepared, null, metrics(14), null, null);
    defer projection.deinit();
    var state: appearance.State = .{ .allocator = std.testing.allocator };
    defer state.deinit();
    try std.testing.expectError(error.ThemeNotPrepared, state.commit(std.testing.io, tmp.dir, &registry, &target, &prepared, &projection, null));
    try std.testing.expectEqualStrings("dark", target.value.ui.theme);
    try std.testing.expect(state.snapshot == null);
    var installation = try themes.Installation.init(&registry, request.draft_id);
    defer installation.deinit();
    try installation.prepare(std.testing.io, tmp.dir, &registry);
    try state.commit(std.testing.io, tmp.dir, &registry, &target, &prepared, &projection, &installation);
    try std.testing.expectEqualStrings(id, target.value.ui.theme);
    try std.testing.expectEqualStrings(id, state.theme.?.id);
    try std.testing.expect(registry.get(id).?.staged_for == null);
}
