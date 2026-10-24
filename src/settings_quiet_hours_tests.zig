const std = @import("std");
const Controller = @import("config/settings_controller.zig").Controller;
const runtime = @import("config/runtime_config.zig");
const schema = @import("config/settings_schema.zig");
const a = std.testing.allocator;
const io = std.testing.io;

test "settings quiet hours signed components cannot save and retain the last valid policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(io, tmp.dir, a, "settings.toml");
    defer target.deinit();
    try target.save(io, tmp.dir, target.value);
    const baseline_revision = target.value.config_revision;
    for ([_][]const u8{ "+1:00-08:00", "22:+1-08:00", "22:00-+1:00", "22:00-08:+1", "25:00-08:00", "22:60-08:00" }) |raw| {
        var controller = try Controller.init(a, target.value);
        defer controller.deinit();
        const rejected = if (controller.editRaw("notify", "quiet_hours", raw)) |_| false else |err| blk: {
            try std.testing.expectEqual(error.InvalidValue, err);
            break :blk true;
        };
        if (!rejected) {
            // RED proves an actual bad configuration write and fresh reload,
            // rather than merely testing the parser helper in isolation.
            try controller.save(io, tmp.dir, &target);
            var restart_bad = try runtime.RuntimeConfig.loadOrDefault(io, tmp.dir, a, "settings.toml");
            defer restart_bad.deinit();
            std.debug.print("invalid quiet_hours unexpectedly saved and reloaded: {s}\n", .{restart_bad.value.notify.quiet_hours});
        }
        try std.testing.expect(rejected);
        try std.testing.expectEqualStrings(raw, controller.raw_fields[schema.find("notify", "quiet_hours").?].input.?);
        try std.testing.expectEqualStrings("22:00-08:00", controller.model.value.notify.quiet_hours);
        try std.testing.expectEqualStrings("22:00-08:00", target.value.notify.quiet_hours);
        try std.testing.expect(!controller.canSave());
        try std.testing.expectError(error.InvalidDraft, controller.save(io, tmp.dir, &target));
        try std.testing.expectEqual(baseline_revision, target.value.config_revision);
        var restart = try runtime.RuntimeConfig.loadOrDefault(io, tmp.dir, a, "settings.toml");
        defer restart.deinit();
        try std.testing.expectEqualStrings("22:00-08:00", restart.value.notify.quiet_hours);
    }
    var corrected = try Controller.init(a, target.value);
    defer corrected.deinit();
    try corrected.editRaw("notify", "quiet_hours", "23:30-07:15");
    try corrected.save(io, tmp.dir, &target);
    var restart = try runtime.RuntimeConfig.loadOrDefault(io, tmp.dir, a, "settings.toml");
    defer restart.deinit();
    try std.testing.expectEqualStrings("23:30-07:15", restart.value.notify.quiet_hours);
}
