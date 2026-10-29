const std = @import("std");
const operation = @import("../host/operation.zig");
const session = @import("../host/session_host.zig");

pub const ExecOpts = struct {
    timeout_ms: u32 = 30_000,
    capture_cap: u32 = 64 * 1024,
    key: ?operation.OperationKey = null,
    call_id: u64 = 0,
    service_binding: ?session.ServiceHandle = null,
    cwd: ?[]const u8 = null,
    group: ?*anyopaque = null,
};
pub const Status = enum { queued, opening, running, completed, cancelled, timed_out, channel_rejected, failed };
/// Fixed-size protocol facts. No command, address, credentials or output is
/// included, so the native owner can record a bounded diagnostic on failure.
pub const Phase = enum { queued, opening, requesting, running, peer_close, closing, releasing, finished };
pub const Diagnostics = struct {
    phase: Phase = .queued,
    stopped_phase: ?Phase = null,
    // true means native exec was entered, not proof of packet delivery or
    // server acceptance. null means this bridge supplied no start evidence.
    request_started: ?bool = null,
    request_accepted: bool = false,
    eof_received: bool = false,
    channel_open_error: ?i32 = null,
    request_error: ?i32 = null,
    read_error: ?i32 = null,
    close_error: ?i32 = null,
    wait_close_error: ?i32 = null,
    release: operation.Cleanup = .not_started,
};
pub const ExecResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: ?i32 = null,
    elapsed_ms: u64,
    key: ?operation.OperationKey = null,
    call_id: u64 = 0,
    service_binding: ?session.ServiceHandle = null,
    command: []const u8 = "",
    cwd: ?[]const u8 = null,
    timeout_ms: u32 = 30_000,
    capture_cap: u32 = 64 * 1024,
    status: Status = .completed,
    truncated: bool = false,
    stdout_bytes: u64 = 0,
    stderr_bytes: u64 = 0,
    effect: operation.Effect = .unknown,
    cleanup: operation.Cleanup = .not_started,
    failure: ?[]const u8 = null,
    diagnostics: Diagnostics = .{},
};
/// Snapshot copies can be read while the IO owner continues draining. Ordinary
/// poll results borrow buffers that stay stable until the call is retired.
pub const OwnedResult = struct {
    arena: std.heap.ArenaAllocator,
    value: ExecResult,
    pub fn deinit(self: *OwnedResult) void {
        self.arena.deinit();
    }
};
pub const ExecHandle = struct { ptr: *anyopaque };
pub const ExecBridge = struct {
    ctx: *anyopaque,
    exec_fn: *const fn (*anyopaque, []const u8, ExecOpts) anyerror!ExecHandle,
    abort_fn: *const fn (ExecHandle) void,
    poll_fn: *const fn (ExecHandle) ?ExecResult,
    close_fn: *const fn (*anyopaque) void,
    snapshot_fn: ?*const fn (ExecHandle, std.mem.Allocator) anyerror!OwnedResult = null,
    close_call_fn: ?*const fn (ExecHandle) anyerror!operation.Cleanup = null,
    pub fn exec(self: *const ExecBridge, cmd: []const u8, opts: ExecOpts) !ExecHandle {
        return self.exec_fn(self.ctx, cmd, opts);
    }
    pub fn abort(self: *const ExecBridge, h: ExecHandle) void {
        self.abort_fn(h);
    }
    pub fn cancel(self: *const ExecBridge, h: ExecHandle) void {
        self.abort(h);
    }
    pub fn poll(self: *const ExecBridge, h: ExecHandle) ?ExecResult {
        return self.poll_fn(h);
    }
    pub fn close(self: *const ExecBridge) void {
        self.close_fn(self.ctx);
    }
    pub fn snapshot(self: *const ExecBridge, h: ExecHandle, allocator: std.mem.Allocator) !OwnedResult {
        return (self.snapshot_fn orelse return error.SnapshotUnsupported)(h, allocator);
    }
    pub fn closeCall(self: *const ExecBridge, h: ExecHandle) !operation.Cleanup {
        return (self.close_call_fn orelse return error.CloseCallUnsupported)(h);
    }
};

test "exec bridge contract rejects empty command and exposes lifecycle" {
    const Fake = struct {
        done: bool = false,
        pub fn exec(ctx: *anyopaque, cmd: []const u8, _: ExecOpts) !ExecHandle {
            if (cmd.len == 0) return error.EmptyCommand;
            return .{ .ptr = ctx };
        }
        pub fn abort(h: ExecHandle) void {
            const self: *@This() = @ptrCast(@alignCast(h.ptr));
            self.done = true;
        }
        pub fn poll(h: ExecHandle) ?ExecResult {
            const self: *@This() = @ptrCast(@alignCast(h.ptr));
            if (!self.done) return null;
            return .{ .stdout = "", .stderr = "", .exit_code = 130, .elapsed_ms = 0 };
        }
        pub fn close(_: *anyopaque) void {}
    };
    var fake: Fake = .{};
    const bridge = ExecBridge{ .ctx = &fake, .exec_fn = Fake.exec, .abort_fn = Fake.abort, .poll_fn = Fake.poll, .close_fn = Fake.close };
    try std.testing.expectError(error.EmptyCommand, bridge.exec("", .{}));
    const h = try bridge.exec("printf ok", .{});
    try std.testing.expect(bridge.poll(h) == null);
    bridge.abort(h);
    try std.testing.expectEqual(@as(?i32, 130), bridge.poll(h).?.exit_code);
}
