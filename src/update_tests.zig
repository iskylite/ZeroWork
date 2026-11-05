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

test "update failures describe the phase before installation" {
    const Status = @import("update/client.zig").Status;
    const checking: Status = .{ .state = 10, .failure_stage = 1 };
    try std.testing.expectEqualStrings("检查更新失败", checking.failureTitle());
    try std.testing.expectEqualStrings("检查失败", checking.failureBadge());
    try std.testing.expect(std.mem.startsWith(u8, checking.failureHint(), "尚未开始下载或安装"));
    const download: Status = .{ .state = 10, .failure_stage = 3 };
    try std.testing.expectEqualStrings("更新下载失败", download.failureTitle());
    const verify: Status = .{ .state = 10, .failure_stage = 4 };
    try std.testing.expectEqualStrings("更新包验证失败", verify.failureTitle());
    const prepare: Status = .{ .state = 10, .failure_stage = 6 };
    try std.testing.expectEqualStrings("安装准备失败", prepare.failureTitle());
}
