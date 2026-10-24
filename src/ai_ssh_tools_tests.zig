const std = @import("std");
const tools = @import("ui/ai_ssh_tools.zig");

test {
    _ = tools;
    _ = @import("ai_file_tool_result_tests.zig");
}

test "SSH AI tools empty controller pump and absent owner are safe without a connection" {
    var bridge = tools.Bridge.init(std.testing.allocator);
    defer bridge.deinit();
    var application: @import("ui/application_host.zig").ApplicationHost = undefined;
    var session_host = try @import("host/session_host.zig").SessionHost.init(std.testing.allocator, &.{});
    application.sessions = &session_host;
    defer application.sessions.deinit();
    try std.testing.expectError(error.StaleSession, bridge.prepare(&application, .{ .session_id = @fromBackingInt(7), .generation = 1 }));
    bridge.pump(&application);
    try std.testing.expectEqual(@import("host/session_host.zig").CloseReceipt.released, bridge.stopOwner(.{ .session_id = @fromBackingInt(7), .generation = 1 }));
    bridge.shutdown(null);
    try bridge.clear();
}
