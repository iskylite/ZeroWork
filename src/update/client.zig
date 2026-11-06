const std = @import("std");
comptime {
    _ = @import("crypto.zig");
}
pub const Status = extern struct {
    state: c_int = 0,
    generation: u64 = 0,
    received: u64 = 0,
    expected: u64 = 0,
    failure_stage: c_int = 0,
    version: [96]u8 = @splat(0),
    message: [2048]u8 = @splat(0),
    notes: [16385]u8 = @splat(0),
    pub fn downloadPercent(self: *const Status) ?f32 {
        if (self.expected == 0) return null;
        return @min(100, @as(f32, @floatFromInt(self.received)) / @as(f32, @floatFromInt(self.expected)) * 100);
    }
    pub fn failureTitle(self: *const Status) []const u8 {
        return switch (self.failure_stage) {
            1 => "检查更新失败",
            3 => "更新下载失败",
            4 => "更新包验证失败",
            6 => "安装准备失败",
            else => "更新失败",
        };
    }
    pub fn failureBadge(self: *const Status) []const u8 {
        return switch (self.failure_stage) {
            1 => "检查失败",
            3 => "下载失败",
            4 => "验证失败",
            6 => "安装失败",
            else => "更新失败",
        };
    }
    pub fn failureHint(self: *const Status) []const u8 {
        return switch (self.failure_stage) {
            1 => "尚未开始下载或安装。可重新检查，或查看官方发布页。",
            3, 4 => "尚未开始安装。可重新检查，或从官方发布页下载安装包。",
            else => "应用尚未退出。可重试，或从官方发布页下载安装包。",
        };
    }
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
