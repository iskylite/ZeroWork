test {
    _ = @import("update/crypto.zig");
    _ = @import("update/close_coordinator.zig");
    _ = @import("config/config.zig");
    _ = @import("config/settings_values.zig");
    _ = @import("config/settings_pages.zig");
}
const std = @import("std");
test "update automatic checking defaults on and participates in config draft save" {
    const Config = @import("config/config.zig").Config;
    const values = @import("config/settings_values.zig");
    const schema = @import("config/settings_schema.zig");
    const original: Config = .{};
    try std.testing.expect(original.updates.auto_check);
    var draft = original;
    try values.writeConfig(&draft, "updates", "auto_check", .{ .boolean = false });
    try std.testing.expect(original.updates.auto_check);
    try std.testing.expect(!draft.updates.auto_check);
    try std.testing.expect(schema.changed(original, draft).isSet(schema.find("updates", "auto_check").?));
    var out: [65536]u8 = undefined;
    const bytes = try draft.format(&out);
    const loaded = try Config.parse(bytes);
    try std.testing.expect(!loaded.updates.auto_check);
}
