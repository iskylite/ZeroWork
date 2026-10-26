//! Real background jobs and their main-thread publication; no window required.
const std = @import("std");
const api = @import("config/appearance_ui_worker.zig");
const themes = @import("config/theme_registry.zig");
const Controller = @import("config/settings_controller.zig").Controller;

fn finish(worker: *api.Worker, controller: ?*Controller, registry: *themes.Registry) !api.Poll {
    for (0..1_000_000) |_| {
        const result = worker.poll(controller, registry, "dark");
        if (!worker.busy()) return result;
        std.Thread.yield() catch {};
    }
    return error.WorkerTimeout;
}
fn sourceFixture(allocator: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, "<plist><dict>");
    for (0..19) |i| {
        const key = if (i < 16) try std.fmt.allocPrint(allocator, "Ansi {d} Color", .{i}) else try allocator.dupe(u8, ([_][]const u8{ "Background Color", "Foreground Color", "Cursor Color" })[i - 16]);
        defer allocator.free(key);
        const row = try std.fmt.allocPrint(allocator, "<key>{s}</key><dict><key>Red Component</key><real>0.2</real><key>Green Component</key><real>0.3</real><key>Blue Component</key><real>0.4</real></dict>", .{key});
        defer allocator.free(row);
        try list.appendSlice(allocator, row);
    }
    try list.appendSlice(allocator, "</dict></plist>");
    return list.toOwnedSlice(allocator);
}
test "appearance worker favorite publishes snapshot without editing the settings draft" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var registry = try themes.Registry.init(a);
    defer registry.deinit();
    var controller = try Controller.init(a, .{});
    defer controller.deinit();
    try std.testing.expectError(error.InvalidValue, controller.editRaw("ui", "font_size", "not a number"));
    var worker = try api.Worker.init(a, std.testing.io, tmp.dir, "themes/favorites.json");
    defer worker.deinit();
    const revision = registry.revision;
    try worker.startFavorite(&registry, "nord", revision, true);
    try std.testing.expect(worker.busy());
    try std.testing.expect(!registry.get("nord").?.favorite);
    try std.testing.expectError(error.AppearanceBusy, worker.startFavorite(&registry, "dark", revision, true));
    const result = try finish(&worker, &controller, &registry);
    try std.testing.expect(result.changed and result.problem == null);
    try std.testing.expect(registry.get("nord").?.favorite);
    try std.testing.expectEqualStrings("dark", controller.model.value.ui.theme);
    try std.testing.expectEqualStrings("not a number", controller.raw_fields[@import("config/settings_schema.zig").find("ui", "font_size").?].input.?);
    var restarted = try themes.Registry.init(a);
    defer restarted.deinit();
    try restarted.loadFavorites(std.testing.io, tmp.dir, "themes/favorites.json");
    try std.testing.expect(restarted.get("nord").?.favorite);
}
test "appearance worker late import is released and background error retains the typed path" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try sourceFixture(a);
    defer a.free(source);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "picked.itermcolors", .data = source });
    var registry = try themes.Registry.init(a);
    defer registry.deinit();
    var controller = try Controller.init(a, .{});
    defer controller.deinit();
    var worker = try api.Worker.init(a, std.testing.io, tmp.dir, "favorites.json");
    defer worker.deinit();
    const obsolete = try controller.requestThemeImport();
    try worker.startThemeImport(obsolete, "picked.itermcolors");
    _ = try controller.requestThemeImport();
    const result = try finish(&worker, &controller, &registry);
    try std.testing.expect(!result.changed and result.problem == null);
    try std.testing.expectEqual(@as(usize, 17), registry.records.items.len);
    try std.testing.expectEqualStrings("dark", controller.model.value.ui.theme);
    var request = try controller.requestBackground("/zerowork-test-missing-image.png");
    try worker.startBackground(&request);
    const failed = try finish(&worker, &controller, &registry);
    try std.testing.expect(failed.changed and failed.problem != null and failed.problem.? == error.FileNotFound);
    try std.testing.expectEqual(.missing, controller.background.state);
    try std.testing.expectEqualStrings("", controller.model.value.ui.materials.background.path);
    try std.testing.expectEqualStrings("/zerowork-test-missing-image.png", worker.selectedPath());
    worker.clearSelectedPath();
    try std.testing.expectEqualStrings("", worker.selectedPath());
}
test "appearance worker abandons installation on its worker after the draft closes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try sourceFixture(a);
    defer a.free(source);
    var registry = try themes.Registry.init(a);
    defer registry.deinit();
    var controller = try Controller.init(a, .{});
    defer controller.deinit();
    const request = try controller.requestThemeImport();
    var imported = try themes.Registry.parseImport(a, request, source, "Owned import");
    try std.testing.expect(try controller.completeThemeImport(&registry, &imported));
    var path_buffer: [80]u8 = undefined;
    const path = try @import("config/imported_theme.zig").managedPath(controller.model.value.ui.theme, &path_buffer);
    var worker = try api.Worker.init(a, std.testing.io, tmp.dir, "favorites.json");
    defer worker.deinit();
    try worker.prepareInstallation(&registry, controller.draft_id);
    const result = try finish(&worker, null, &registry);
    try std.testing.expect(result.problem == null and worker.takeInstallation() == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, path, .{}));
    try std.testing.expect(registry.get(controller.model.value.ui.theme).?.staged_for == controller.draft_id);
}

test "appearance worker GPU admission failure preserves the last good path and skips stale work" {
    const a = std.testing.allocator;
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
        "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++
        "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "first.png", .data = png });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "second.png", .data = png });
    const first = try tmp.dir.realPathFileAlloc(std.testing.io, "first.png", a);
    defer a.free(first);
    const second = try tmp.dir.realPathFileAlloc(std.testing.io, "second.png", a);
    defer a.free(second);
    var registry = try themes.Registry.init(a);
    defer registry.deinit();
    var controller = try Controller.init(a, .{});
    defer controller.deinit();
    const Spy = struct {
        prepares: usize = 0,
        completes: usize = 0,
        reject: bool = false,
        fn prepare(raw: *anyopaque, _: *const @import("config/background_asset.zig").Prepared) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.prepares += 1;
            if (self.reject) return error.TextureAllocationFailed;
        }
        fn complete(raw: *anyopaque, accepted: bool) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(accepted);
            self.completes += 1;
        }
    };
    var spy: Spy = .{};
    var worker = try api.Worker.init(a, std.testing.io, tmp.dir, "favorites.json");
    defer worker.deinit();
    worker.background_preflight = .{ .context = &spy, .prepare = Spy.prepare, .complete = Spy.complete };
    var initial = try controller.requestBackground(first);
    try worker.startBackground(&initial);
    try std.testing.expect((try finish(&worker, &controller, &registry)).changed);
    const old_pixels = controller.background.last_good.?.image.pixels.ptr;
    spy.reject = true;
    var replacement = try controller.requestBackground(second);
    try worker.startBackground(&replacement);
    const failed = try finish(&worker, &controller, &registry);
    try std.testing.expect(failed.problem != null and failed.problem.? == error.TextureAllocationFailed);
    try std.testing.expectEqualStrings(first, controller.model.value.ui.materials.background.path);
    try std.testing.expectEqual(old_pixels, controller.background.last_good.?.image.pixels.ptr);
    try std.testing.expectEqual(@as(usize, 2), spy.prepares);
    try std.testing.expectEqual(@as(usize, 1), spy.completes);
    var obsolete = try controller.requestBackground(second);
    try worker.startBackground(&obsolete);
    var latest = try controller.requestBackground(first);
    latest.deinit();
    const stale = try finish(&worker, &controller, &registry);
    try std.testing.expect(!stale.changed);
    try std.testing.expectEqual(@as(usize, 2), spy.prepares);
    try std.testing.expectEqual(old_pixels, controller.background.last_good.?.image.pixels.ptr);
}

test "appearance worker prepares a retained background after reopening disabled settings" {
    const a = std.testing.allocator;
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
        "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++
        "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "background.png", .data = png });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "background.png", a);
    defer a.free(path);
    var target = try @import("config/runtime_config.zig").RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, a, "config.toml");
    defer target.deinit();
    try target.updateSetting(std.testing.io, tmp.dir, "ui.materials.background", "path", .{ .text = path });
    var registry = try themes.Registry.init(a);
    defer registry.deinit();
    var worker = try api.Worker.init(a, std.testing.io, tmp.dir, "favorites.json");
    defer worker.deinit();
    // A new settings draft owns no decoded asset when the saved toggle is off.
    var controller = try Controller.init(a, target.value);
    defer controller.deinit();
    try std.testing.expectEqual(.empty, controller.background.state);
    try std.testing.expect(controller.background.last_good == null);
    try controller.editKey("ui.materials.background", "enabled", .{ .boolean = true });
    try std.testing.expectEqual(.dirty_invalid, controller.state());
    try std.testing.expect(!controller.canSave());
    // The host's draft-values notification must schedule this owned request.
    var request = try controller.requestBackground(controller.model.value.ui.materials.background.path);
    try worker.startBackground(&request);
    const result = try finish(&worker, &controller, &registry);
    try std.testing.expect(result.changed and result.problem == null);
    try std.testing.expectEqual(.ready, controller.background.state);
    try std.testing.expectEqual(.dirty_valid, controller.state());
    try std.testing.expect(controller.canSave());
    try controller.save(std.testing.io, tmp.dir, &target);
    try std.testing.expect(target.value.ui.materials.background.enabled);
    try std.testing.expectEqualStrings(path, target.value.ui.materials.background.path);
    try std.testing.expectEqual(.clean, controller.state());
}
