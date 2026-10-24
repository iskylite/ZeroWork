//! Documented driver defects; runtime self-tests select atomic workarounds.
const std = @import("std");
const DriverInfo = @import("driver_info.zig").DriverInfo;

pub const DriverBugs = packed struct(u32) {
    /// Lower divergent buffer array atomics to constant-index switch cases.
    non_uniform_uav_buffer_array_atomics: bool = false,
    _padding: u31 = 0,
};
const Rule = struct { vendor_id: u32, device_id: u32, driver_version: [4]u16, bugs: DriverBugs };
// Arc 140T: raw and structured nonuniform array atomics fail with clean D3D12
// debug/GBV validation. Only this measured device and exact version are listed.
const d3d12_rules = [_]Rule{.{
    .vendor_id = 0x8086,
    .device_id = 0x7d51,
    .driver_version = .{ 32, 0, 101, 8826 },
    .bugs = .{ .non_uniform_uav_buffer_array_atomics = true },
}};

pub fn forD3D12(info: DriverInfo) DriverBugs {
    if (info.software) return .{};
    const version = info.driver_version orelse return .{};
    for (d3d12_rules) |rule| {
        if (info.vendor_id == rule.vendor_id and info.device_id == rule.device_id and
            std.mem.eql(u16, &version, &rule.driver_version)) return rule.bugs;
    }
    return .{};
}

test "only the measured hardware and exact driver version match" {
    const affected: DriverInfo = .{ .vendor_id = 0x8086, .device_id = 0x7d51, .driver_version = .{ 32, 0, 101, 8826 } };
    try std.testing.expect(forD3D12(affected).non_uniform_uav_buffer_array_atomics);
    var other = affected;
    other.vendor_id = 0x10de;
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(forD3D12(other))));
    other = affected;
    other.device_id = 0x7d55;
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(forD3D12(other))));
    for ([_][4]u16{ .{ 32, 0, 101, 8825 }, .{ 32, 0, 101, 8827 }, .{ 31, 0, 101, 8826 } }) |version| {
        other = affected;
        other.driver_version = version;
        try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(forD3D12(other))));
    }
}

test "software and unknown versions never match a hardware defect" {
    const affected: DriverInfo = .{ .vendor_id = 0x8086, .device_id = 0x7d51, .driver_version = .{ 32, 0, 101, 8826 } };
    var other = affected;
    other.software = true;
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(forD3D12(other))));
    other = affected;
    other.driver_version = null;
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(forD3D12(other))));
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(forD3D12(.{}))));
}
