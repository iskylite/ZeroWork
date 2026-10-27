//! Real owned settings draft -> atomic file -> fresh runtime checks for every
//! scalar schema entry. This does not claim any field's runtime consumer works.
const std = @import("std");
const config = @import("config/config.zig");
const controller_mod = @import("config/settings_controller.zig");
const runtime = @import("config/runtime_config.zig");
const values = @import("config/settings_values.zig");
const schema = @import("config/settings_schema.zig");
const a = std.testing.allocator;
const io = std.testing.io;

fn nextValue(value: config.Config, entry: @TypeOf(schema.fields[0])) !values.Value {
    const old = values.read(value, entry.section, entry.key) orelse return error.UnknownKey;
    switch (old) {
        .boolean => |v| return .{ .boolean = !v },
        .unsigned => |v| return .{ .unsigned = if (std.mem.eql(u8, entry.section, "ssh") and std.mem.eql(u8, entry.key, "reconnect_max")) v - 1 else v + 1 },
        .decimal => |v| return .{ .decimal = v + 0.25 },
        .text => {},
    }
    const choices = [_]struct { section: []const u8, key: []const u8, text: []const u8 }{
        .{ .section = "ui", .key = "icon_background", .text = "dark" },
        .{ .section = "ui", .key = "theme", .text = "light" },
        .{ .section = "ui", .key = "font_family", .text = "Menlo" },
        .{ .section = "ui", .key = "font_weight", .text = "bold" },
        .{ .section = "ui", .key = "cursor_style", .text = "block" },
        .{ .section = "ssh", .key = "term", .text = "vt100" },
        .{ .section = "ssh", .key = "reconnect_backoff", .text = "[2,3,5,8,13]" },
        .{ .section = "ssh", .key = "socks_bind", .text = "0.0.0.0" },
        .{ .section = "transfer", .key = "download_dir", .text = "/fixture/settings-download" },
        .{ .section = "ai", .key = "default_provider", .text = "audit-provider" },
        .{ .section = "ai", .key = "permission_mode", .text = "auto" },
        .{ .section = "notify", .key = "quiet_hours", .text = "23:00-07:00" },
        .{ .section = "log", .key = "export_format", .text = "txt" },
        .{ .section = "ui.materials.background", .key = "path", .text = "/fixture/settings-background.png" },
        .{ .section = "ui.materials.background", .key = "fit", .text = "fit" },
        .{ .section = "ui.materials.background", .key = "alignment_x", .text = "left" },
        .{ .section = "ui.materials.background", .key = "alignment_y", .text = "top" },
    };
    for (choices) |choice| if (std.mem.eql(u8, entry.section, choice.section) and std.mem.eql(u8, entry.key, choice.key)) return .{ .text = choice.text };
    return error.MissingAuditValue;
}

test "settings scalar lifecycle covers every schema field through cancel save restart and restored defaults" {
    var checked: usize = 0;
    for (schema.fields, 0..) |entry, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var original: config.Config = .{};
        // Exercise disabling an existing image without fabricating decode or
        // GPU receipts. Other image properties are persisted while disabled.
        if (std.mem.eql(u8, entry.section, "ui.materials.background") and std.mem.eql(u8, entry.key, "enabled")) {
            original.ui.materials.background.enabled = true;
            original.ui.materials.background.path = "/fixture/existing-background.png";
        }
        var storage: [32768]u8 = undefined;
        try tmp.dir.writeFile(io, .{ .sub_path = "settings.toml", .data = try original.format(&storage) });
        var target = try runtime.RuntimeConfig.loadOrDefault(io, tmp.dir, a, "settings.toml");
        defer target.deinit();
        var c = try controller_mod.Controller.init(a, target.value);
        defer c.deinit();
        if (std.mem.eql(u8, entry.section, "transfer") and std.mem.eql(u8, entry.key, "conflict_policy")) {
            // The actual product offers exactly one value. An unsupported
            // automatic overwrite must remain invalid, then discard restores.
            try std.testing.expectError(error.InvalidValue, c.editKey(entry.section, entry.key, .{ .text = "overwrite" }));
            try std.testing.expect(!c.canSave());
            c.discard();
            try std.testing.expect(schema.fieldEqual(c.model.value, original, index));
        } else {
            const next = try nextValue(original, entry);
            c.editKey(entry.section, entry.key, next) catch |err| {
                std.debug.print("edit failed {s}.{s}: {s}\n", .{ entry.section, entry.key, @errorName(err) });
                return err;
            };
            try std.testing.expect(c.dirty_fields.isSet(index));
            c.model.selectPage(7);
            c.model.selectPage(0);
            c.discard();
            try std.testing.expect(schema.fieldEqual(c.model.value, original, index));
            try std.testing.expect(schema.fieldEqual(target.value, original, index));
            try c.editKey(entry.section, entry.key, next);
            var expected = try runtime.Snapshot.init(a, c.model.value);
            defer expected.deinit();
            c.save(io, tmp.dir, &target) catch |err| {
                std.debug.print("save failed {s}.{s}: {s}\n", .{ entry.section, entry.key, @errorName(err) });
                return err;
            };
            try std.testing.expect(!c.model.dirty);
            var restarted = try runtime.RuntimeConfig.loadOrDefault(io, tmp.dir, a, "settings.toml");
            defer restarted.deinit();
            try std.testing.expect(schema.fieldEqual(restarted.value, expected.value, index));
            c.resetDefaults();
            c.discard();
            try std.testing.expect(schema.fieldEqual(c.model.value, expected.value, index));
        }
        c.resetDefaults();
        try c.save(io, tmp.dir, &target);
        var defaults_restarted = try runtime.RuntimeConfig.loadOrDefault(io, tmp.dir, a, "settings.toml");
        defer defaults_restarted.deinit();
        try std.testing.expect(schema.fieldEqual(defaults_restarted.value, config.resetDefaults(), index));
        checked += 1;
    }
    try std.testing.expectEqual(schema.fields.len, checked);
}
