//! Visual-only command metadata policy. Re-evaluate after settings/host edits;
//! this does not alter shell integration, recording, timestamps, or execution.
const std = @import("std");
const hosts = @import("hosts.zig");

pub fn enabled(global: bool, local: bool, snapshot: ?hosts.HostConfig, registry: ?*const hosts.Registry) bool {
    if (local) return global;
    const saved = snapshot orelse return global;
    if (!std.mem.eql(u8, saved.protocolId(), "ssh")) return false;
    var override = saved.command_info;
    if (registry) |current| if (@backingInt(saved.connection_id) != 0) {
        if (current.indexOf(saved.connection_id)) |index| override = current.hosts[index].command_info;
    };
    return override orelse global;
}

test "command info resolves current global and host overrides without freezing live display" {
    var registry = try hosts.Registry.parse(std.testing.allocator, "[[hosts]] name=\"saved\";host=\"h\";user=\"u\"\n");
    defer registry.deinit();
    const snapshot = registry.hosts[0];
    try std.testing.expect(enabled(true, false, snapshot, &registry));
    try std.testing.expect(!enabled(false, false, snapshot, &registry));
    registry.hosts[0].command_info = true;
    try std.testing.expect(enabled(false, false, snapshot, &registry));
    registry.hosts[0].command_info = false;
    try std.testing.expect(!enabled(true, false, snapshot, &registry));
    try std.testing.expect(enabled(true, true, snapshot, &registry));
    try std.testing.expect(!enabled(false, true, snapshot, &registry));
    registry.hosts[0].command_info = null;
    try std.testing.expect(enabled(true, false, snapshot, &registry));
    var quick = snapshot;
    quick.connection_id = @fromBackingInt(0);
    quick.command_info = false;
    try std.testing.expect(!enabled(true, false, quick, &registry));
    try std.testing.expect(!enabled(true, false, quick, null));
    quick.protocol = .sftp;
    quick.command_info = true;
    try std.testing.expect(!enabled(true, false, quick, &registry));
}
