//! Real managed-theme receipts and Config persistence in isolated directories.
const std = @import("std");
const themes = @import("config/theme_registry.zig");
const importer = @import("config/imported_theme.zig");
const RuntimeConfig = @import("config/runtime_config.zig").RuntimeConfig;

fn sourceFixture(allocator: std.mem.Allocator) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>");
    for (0..19) |index| {
        const key = if (index < 16) try std.fmt.allocPrint(allocator, "Ansi {d} Color", .{index}) else try allocator.dupe(u8, ([_][]const u8{ "Background Color", "Foreground Color", "Cursor Color" })[index - 16]);
        defer allocator.free(key);
        const entry = try std.fmt.allocPrint(allocator, "<key>{s}</key><dict><key>Red Component</key><real>0.25</real>" ++
            "<key>Green Component</key><real>0.5</real><key>Blue Component</key><real>0.75</real></dict>", .{key});
        defer allocator.free(entry);
        try source.appendSlice(allocator, entry);
    }
    try source.appendSlice(allocator, "</dict></plist>");
    return source.toOwnedSlice(allocator);
}

fn stage(registry: *themes.Registry, dir: std.Io.Dir, request: themes.ImportRequest, path: []const u8) ![]const u8 {
    var result = try themes.Registry.readImport(std.testing.io, dir, registry.allocator, request, path);
    return (try registry.completeImport(request, &result)).?;
}

fn expectOriginal(dir: std.Io.Dir, expected: []const u8) !void {
    const bytes = try dir.readFileAlloc(std.testing.io, "user-selected.itermcolors", std.testing.allocator, .limited(importer.max_source_bytes));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

test "theme installation Config save failure aborts only its new copy and retains draft registry" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try sourceFixture(allocator);
    defer allocator.free(source);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "user-selected.itermcolors", .data = source });
    const original_path = try tmp.dir.realPathFileAlloc(std.testing.io, "user-selected.itermcolors", allocator);
    defer allocator.free(original_path);
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, allocator, "blocked/config.toml");
    defer runtime.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocked", .data = "not a directory" });
    var registry = try themes.Registry.init(allocator);
    defer registry.deinit();
    const request: themes.ImportRequest = .{ .draft_id = 71, .operation_id = 1 };
    const id = try stage(&registry, tmp.dir, request, original_path);
    const registry_revision = registry.revision;
    const config_revision = runtime.value.config_revision;
    var path_buffer: [80]u8 = undefined;
    const managed_path = try importer.managedPath(id, &path_buffer);
    var receipt = try themes.Installation.init(&registry, request.draft_id);
    defer {
        receipt.abort(std.testing.io, tmp.dir) catch unreachable;
        receipt.deinit();
    }
    try receipt.prepare(std.testing.io, tmp.dir, &registry);
    try std.testing.expect(receipt.ready and receipt.entries[0].created);
    try tmp.dir.access(std.testing.io, managed_path, .{});
    try receipt.validate(&registry);
    var candidate = runtime.value;
    candidate.ui.theme = id;
    try std.testing.expectError(error.NotDir, runtime.save(std.testing.io, tmp.dir, candidate));
    try std.testing.expectEqual(config_revision, runtime.value.config_revision);
    try std.testing.expectEqualStrings("dark", runtime.value.ui.theme);
    try std.testing.expectEqual(registry_revision, registry.revision);
    try std.testing.expectEqual(@as(?u64, request.draft_id), registry.get(id).?.staged_for);
    try std.testing.expect(registry.get(id).?.managed_source == null);
    try std.testing.expectEqualSlices(u8, source, registry.get(id).?.source_bytes.?);

    try receipt.abort(std.testing.io, tmp.dir);
    try std.testing.expect(!receipt.ready and !receipt.entries[0].created);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, managed_path, .{}));
    try std.testing.expectEqual(registry_revision, registry.revision);
    try std.testing.expectEqualSlices(u8, source, registry.get(id).?.source_bytes.?);
    try expectOriginal(tmp.dir, source);
    var restarted = try themes.Registry.init(allocator);
    defer restarted.deinit();
    try restarted.loadInstalled(std.testing.io, tmp.dir);
    try std.testing.expect(restarted.get(id) == null);
}

test "theme installation abort preserves a matching copy owned by a previous receipt" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try sourceFixture(allocator);
    defer allocator.free(source);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "user-selected.itermcolors", .data = source });
    var first = try themes.Registry.init(allocator);
    defer first.deinit();
    const request: themes.ImportRequest = .{ .draft_id = 81, .operation_id = 1 };
    const first_id = try stage(&first, tmp.dir, request, "user-selected.itermcolors");
    var initial_receipt = try themes.Installation.init(&first, request.draft_id);
    defer {
        initial_receipt.abort(std.testing.io, tmp.dir) catch unreachable;
        initial_receipt.deinit();
    }
    try initial_receipt.prepare(std.testing.io, tmp.dir, &first);
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, allocator, "config.toml");
    defer runtime.deinit();
    var candidate = runtime.value;
    candidate.ui.theme = first_id;
    try initial_receipt.validate(&first);
    try runtime.save(std.testing.io, tmp.dir, candidate);
    initial_receipt.commit(&first);
    const path = first.get(first_id).?.managed_source.?;
    const before = try tmp.dir.readFileAlloc(std.testing.io, path, allocator, .limited(importer.max_managed_bytes));
    defer allocator.free(before);

    // A separate draft/registry sees already installed identical content.
    var second = try themes.Registry.init(allocator);
    defer second.deinit();
    const second_request: themes.ImportRequest = .{ .draft_id = 82, .operation_id = 2 };
    const second_id = try stage(&second, tmp.dir, second_request, "user-selected.itermcolors");
    try std.testing.expectEqualStrings(first_id, second_id);
    const second_revision = second.revision;
    var reused = try themes.Installation.init(&second, second_request.draft_id);
    defer {
        reused.abort(std.testing.io, tmp.dir) catch unreachable;
        reused.deinit();
    }
    try reused.prepare(std.testing.io, tmp.dir, &second);
    try std.testing.expect(reused.ready and !reused.entries[0].created);
    try reused.abort(std.testing.io, tmp.dir);
    const after = try tmp.dir.readFileAlloc(std.testing.io, path, allocator, .limited(importer.max_managed_bytes));
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectEqual(second_revision, second.revision);
    try std.testing.expectEqual(@as(?u64, second_request.draft_id), second.get(second_id).?.staged_for);
    try std.testing.expect(second.get(second_id).?.managed_source == null);
    try expectOriginal(tmp.dir, source);
}

test "theme installation successful Config commit reloads stable identity and removes only managed copy" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try sourceFixture(allocator);
    defer allocator.free(source);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "user-selected.itermcolors", .data = source });
    const original_path = try tmp.dir.realPathFileAlloc(std.testing.io, "user-selected.itermcolors", allocator);
    defer allocator.free(original_path);
    var registry = try themes.Registry.init(allocator);
    defer registry.deinit();
    const request: themes.ImportRequest = .{ .draft_id = 91, .operation_id = 1 };
    const id = try stage(&registry, tmp.dir, request, original_path);
    const registry_revision = registry.revision;
    var path_buffer: [80]u8 = undefined;
    const path = try importer.managedPath(id, &path_buffer);
    var receipt = try themes.Installation.init(&registry, request.draft_id);
    defer {
        receipt.abort(std.testing.io, tmp.dir) catch unreachable;
        receipt.deinit();
    }
    try receipt.prepare(std.testing.io, tmp.dir, &registry);
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, allocator, "config.toml");
    defer runtime.deinit();
    var candidate = runtime.value;
    candidate.ui.theme = id;
    try receipt.validate(&registry);
    try runtime.save(std.testing.io, tmp.dir, candidate);
    receipt.commit(&registry);
    const installed = registry.get(id).?;
    try std.testing.expectEqualStrings(path, installed.managed_source.?);
    try std.testing.expect(installed.staged_for == null and installed.source_bytes == null);
    try std.testing.expectEqual(registry_revision + 1, registry.revision);
    try std.testing.expect(!receipt.entries[0].created and receipt.entries[0].path == null);

    var loaded_runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, allocator, "config.toml");
    defer loaded_runtime.deinit();
    try std.testing.expectEqualStrings(id, loaded_runtime.value.ui.theme);
    var loaded_registry = try themes.Registry.init(allocator);
    defer loaded_registry.deinit();
    try loaded_registry.loadInstalled(std.testing.io, tmp.dir);
    const loaded = loaded_registry.get(loaded_runtime.value.ui.theme).?;
    try std.testing.expectEqualStrings(id, loaded.id);
    try std.testing.expectEqualStrings(installed.theme.name, loaded.theme.name);
    try std.testing.expectEqualStrings(path, loaded.managed_source.?);
    try std.testing.expectEqualSlices(u32, &installed.theme.ansi, &loaded.theme.ansi);
    try std.testing.expectEqual(installed.theme.bg, loaded.theme.bg);
    try std.testing.expect(loaded.staged_for == null and loaded.source_bytes == null);
    try std.testing.expectError(error.CurrentThemeProtected, loaded_registry.remove(std.testing.io, tmp.dir, id, loaded_registry.revision, .{ .saved = loaded_runtime.value.ui.theme, .draft = "dark" }));
    try tmp.dir.access(std.testing.io, path, .{});

    try loaded_runtime.updateSetting(std.testing.io, tmp.dir, "ui", "theme", .{ .text = "dark" });
    try loaded_registry.remove(std.testing.io, tmp.dir, id, loaded_registry.revision, .{ .saved = loaded_runtime.value.ui.theme, .draft = "dark" });
    try std.testing.expect(loaded_registry.get(id) == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, path, .{}));
    try expectOriginal(tmp.dir, source);
    var after_remove = try themes.Registry.init(allocator);
    defer after_remove.deinit();
    try after_remove.loadInstalled(std.testing.io, tmp.dir);
    try std.testing.expectEqual(@as(usize, 0), after_remove.counts().imported);
}
