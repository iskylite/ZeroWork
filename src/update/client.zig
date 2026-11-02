const std = @import("std");
comptime {
    _ = @import("crypto.zig");
}
pub const Status = extern struct {
    state: c_int = 0,
    generation: u64 = 0,
    received: u64 = 0,
    expected: u64 = 0,
    version: [96]u8 = @splat(0),
    message: [2048]u8 = @splat(0),
    notes: [16385]u8 = @splat(0),
    pub fn versionText(self: *const Status) []const u8 {
        return std.mem.sliceTo(&self.version, 0);
    }
    pub fn messageText(self: *const Status) []const u8 {
        return std.mem.sliceTo(&self.message, 0);
    }
    pub fn notesText(self: *const Status) []const u8 {
        return std.mem.sliceTo(&self.notes, 0);
    }
};
pub extern fn zw_update_startup_gate(data: [*:0]const u8) c_int;
pub extern fn zw_update_healthy() void;
pub extern fn zw_update_start(auto_check: c_int) void;
pub extern fn zw_update_set_automatic(enabled: c_int) void;
pub extern fn zw_update_status(out: *Status) void;
pub extern fn zw_update_tick() void;
pub extern fn zw_update_open() void;
pub extern fn zw_update_take_present() c_int;
pub extern fn zw_update_command(command: c_int) void;
pub extern fn zw_update_can_install(reason: [*]u8, len: usize) c_int;
pub extern fn zw_update_prepare(snapshot: [*:0]const u8, colors: [*]const f32) void;
pub extern fn zw_update_save_snapshot(snapshot: [*:0]const u8) c_int;
