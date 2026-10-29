//! Darwin process ABI. One process worker owns each instance. Start can block
//! on OS creation; do not call it from a UI callback. No UI or SSH dependency.
const std = @import("std");
const identity = @import("../host/identity.zig");
const operation = @import("../host/operation.zig");

pub const Process = opaque {};
pub const Stage = enum(c_int) { cwd = 1, pty, pipes, spawn, ownership };
pub const Failure = extern struct {
    stage: Stage = .cwd,
    error_number: c_int = 0,

    pub fn hostFailure(self: Failure) operation.Failure {
        return .{ .domain = .transport, .code = "LocalStartFailed", .stage = @tagName(self.stage), .retryable = self.stage != .ownership, .cleanup = if (self.stage == .ownership) .unknown else .released, .safe_message = switch (self.stage) {
            .cwd => "无法进入本地终端的初始目录",
            .pty => "无法创建本地伪终端",
            .pipes => "无法创建本地命令输出管道",
            .spawn => "无法启动 /bin/zsh",
            .ownership => "无法核实已创建的本地进程身份",
        } };
    }
};
pub const RawExit = extern struct { kind: c_int, value: c_int };
pub const ObservationFailure = extern struct { stage: c_int, error_number: c_int, pid: c_int };
pub const Exit = @import("../host/process_service.zig").ProcessExit;
pub const Foreground = @import("../host/process_service.zig").Foreground;
pub const Read = union(enum) { bytes: usize, would_block, eof };
pub const Write = union(enum) { bytes: usize, would_block };
pub const Cleanup = enum { awaiting, released, unknown };

pub extern fn zw_local_start_pty(?[*:0]const u8, [*:0]const u8, u16, u16, *Failure) ?*Process;
pub extern fn zw_local_start_pty_edit(?[*:0]const u8, [*:0]const u8, u16, u16, ?[*:0]const u8, *Failure) ?*Process;
pub extern fn zw_local_start_exec(?[*:0]const u8, [*:0]const u8, *Failure) ?*Process;
pub extern fn zw_local_read(*Process, c_int, [*]u8, usize, *usize) c_int;
pub extern fn zw_local_write(*Process, [*]const u8, usize, *usize) c_int;
pub extern fn zw_local_resize(*Process, u16, u16) c_int;
pub extern fn zw_local_dimensions(*Process, *u16, *u16) c_int;
pub extern fn zw_local_poll_exit(*Process, *RawExit) c_int;
pub extern fn zw_local_foreground(*Process, *Foreground) c_int;
pub extern fn zw_local_interrupt_foreground(*Process) c_int;
pub extern fn zw_local_poll_fd(*Process) c_int;
pub extern fn zw_local_pid(*Process) c_int;
pub extern fn zw_local_initial_cwd(*Process) [*:0]const u8;
pub extern fn zw_local_cwd(*Process, [*]u8, usize) c_int;
pub extern fn zw_local_close_step(*Process, u64) c_int;
pub extern fn zw_local_observation_failure(*Process, *ObservationFailure) c_int;
pub extern fn zw_local_destroy(*Process) c_int;
pub extern fn zw_local_monotonic_ms() u64;
pub extern fn zw_local_last_error() c_int;

pub fn validateOwner(owner: identity.SessionHandle, key: operation.OperationKey) !void {
    if (@backingInt(owner.session_id) == 0 or owner.generation == 0 or key.operation_id == 0 or key.attempt_id == 0) return error.InvalidIdentity;
    if (key.owner != .session or !key.owner.session.eql(owner)) return error.WrongOwner;
}
pub fn validateString(value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidText;
}
pub fn cwdZ(allocator: std.mem.Allocator, cwd: ?[]const u8) !?[:0]u8 {
    const value = cwd orelse return null;
    try validateString(value);
    if (value.len == 0 or value[0] != '/') return error.InvalidDirectory;
    return try allocator.dupeSentinel(u8, value, 0);
}
pub fn read(process: *Process, stream: c_int, buffer: []u8) !Read {
    var count: usize = 0;
    return switch (zw_local_read(process, stream, buffer.ptr, buffer.len, &count)) {
        0 => .would_block,
        1 => .{ .bytes = count },
        2 => .eof,
        else => error.ReadFailed,
    };
}
pub fn pollExit(process: *Process) !?Exit {
    var raw: RawExit = undefined;
    return switch (zw_local_poll_exit(process, &raw)) {
        0 => null,
        1 => if (raw.kind == 1) .{ .exited = @intCast(raw.value) } else .{ .signal = @intCast(raw.value) },
        else => error.ExitUnknown,
    };
}
pub fn closeStep(process: *Process) Cleanup {
    return switch (zw_local_close_step(process, zw_local_monotonic_ms())) {
        0 => .awaiting,
        1 => .released,
        else => .unknown,
    };
}
