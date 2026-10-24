const builtin = @import("builtin");
const linux = @import("backends/linux.zig");

test {
    // macOS helpers use native Cocoa text and drag event types. Linux's
    // mock-backed adapter contracts can also run on the macOS development host.
    if (builtin.os.tag == .macos) _ = @import("backends/macos.zig");
    _ = linux;
}

// ── cursor vtable optional set_custom contract ────────────────────────────────
// set_custom is optional field: when missing customCursorSupported()==false,
// setCustomCursor returns NotSupported (UI layer falls back to fixed shapes).

const std = @import("std");
const api = @import("api.zig");
const vtable_mod = @import("vtable.zig");
const events_mod = @import("events.zig");
const errors_mod = @import("errors.zig");

const CursorOnlyBackend = struct {
    shape_calls: u32 = 0,

    fn deinitFn(_: *anyopaque, _: std.mem.Allocator) void {}

    fn pump(_: *anyopaque, _: *events_mod.EventQueue, _: u32) errors_mod.SdkError!vtable_mod.PumpResult {
        return .{};
    }

    fn setShape(ctx_: *anyopaque, _: events_mod.WindowId, _: u8) errors_mod.SdkError!void {
        const self: *@This() = @ptrCast(@alignCast(ctx_));
        self.shape_calls += 1;
    }
};

test "SystemSdk: custom cursor degrades when vtable lacks set_custom" {
    var backend = CursorOnlyBackend{};
    const vt = vtable_mod.BackendVTable{
        .name = "cursor-only-mock",
        .deinit = CursorOnlyBackend.deinitFn,
        .pump_events = CursorOnlyBackend.pump,
        .cursor = .{ .set_shape = CursorOnlyBackend.setShape },
    };
    var sdk = api.SystemSdk.init(std.testing.allocator, &backend, &vt, .{ .cursor = true });
    defer sdk.deinit();

    try std.testing.expect(!sdk.customCursorSupported());
    const pixels = @as([16]u8, @splat(0));
    try std.testing.expectError(
        error.NotSupported,
        sdk.setCustomCursor(1, .{ .rgba = &pixels, .width = 2, .height = 2, .scale = 2, .hot_x = 0, .hot_y = 0, .key = 7 }),
    );
    // Fixed shape path unaffected
    try sdk.setCursorShape(1, 4);
    try std.testing.expectEqual(@as(u32, 1), backend.shape_calls);
}
