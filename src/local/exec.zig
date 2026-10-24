//! Independent local exec. Never writes the user's interactive PTY.
const std = @import("std");
const identity = @import("../host/identity.zig");
const operation = @import("../host/operation.zig");
const native = @import("native.zig");
pub const Limits = @import("../host/process_service.zig").ExecLimits;
pub const Result = struct {
    owner: identity.SessionHandle,
    call_id: u64,
    stdout: []const u8,
    stderr: []const u8,
    exit: ?native.Exit,
    cancelled: bool,
    timed_out: bool,
    truncated: bool,
    cleanup: native.Cleanup,
};

pub const Command = struct {
    allocator: std.mem.Allocator,
    owner: identity.SessionHandle,
    operation_key: operation.OperationKey,
    call_id: u64,
    process: ?*native.Process,
    limits: Limits,
    started_ms: u64,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    exit: ?native.Exit = null,
    stdout_eof: bool = false,
    stderr_eof: bool = false,
    cancelled: bool = false,
    timed_out: bool = false,
    truncated: bool = false,
    cleanup: native.Cleanup = .awaiting,

    /// command is explicit shell text; cwd travels only through fchdir and can
    /// never become part of the command. Permissions belong to the caller.
    pub fn start(allocator: std.mem.Allocator, owner: identity.SessionHandle, key: operation.OperationKey, call_id: u64, command: []const u8, cwd: ?[]const u8, limits: Limits, failure: *native.Failure) !Command {
        try native.validateOwner(owner, key);
        if (call_id == 0) return error.InvalidIdentity;
        if (command.len == 0) return error.EmptyCommand;
        if (command.len > 1024 * 1024 or limits.capture_bytes == 0 or limits.capture_bytes > 16 * 1024 * 1024) return error.InvalidLimits;
        try native.validateString(command);
        const cwd_z = try native.cwdZ(allocator, cwd);
        defer if (cwd_z) |value| allocator.free(value);
        const text = try allocator.dupeSentinel(u8, command, 0);
        defer allocator.free(text);
        // Reserve the full bounded capture before spawning. OOM cannot leave a
        // child that was started without space for its required output state.
        var stdout: std.ArrayList(u8) = .empty;
        errdefer stdout.deinit(allocator);
        var stderr: std.ArrayList(u8) = .empty;
        errdefer stderr.deinit(allocator);
        try stdout.ensureTotalCapacity(allocator, limits.capture_bytes);
        try stderr.ensureTotalCapacity(allocator, limits.capture_bytes);
        const process = native.zw_local_start_exec(if (cwd_z) |value| value.ptr else null, text.ptr, failure) orelse return error.StartFailed;
        return .{ .allocator = allocator, .owner = owner, .operation_key = key, .call_id = call_id, .process = process, .limits = limits, .started_ms = native.zw_local_monotonic_ms(), .stdout = stdout, .stderr = stderr };
    }
    pub fn pid(self: *const Command) !i32 {
        return native.zw_local_pid(self.process orelse return error.CommandReleased);
    }
    pub fn cancel(self: *Command, owner: identity.SessionHandle) !void {
        if (!self.owner.eql(owner)) return error.StaleSession;
        if (self.process == null) return error.CommandReleased;
        if (self.cleanup == .released) return;
        self.cancelled = true;
    }
    fn drain(self: *Command, stream: c_int) !void {
        var buffer: [4096]u8 = undefined;
        // Bound work per poll, including discarded overflow, so a producer
        // cannot starve timeout/cancellation by continuously filling a pipe.
        for (0..16) |_| {
            switch (try native.read(self.process.?, stream, &buffer)) {
                .bytes => |count| {
                    const remaining = self.limits.capture_bytes - self.stdout.items.len - self.stderr.items.len;
                    const keep = @min(remaining, count);
                    const destination = if (stream == 0) &self.stdout else &self.stderr;
                    destination.appendSliceAssumeCapacity(buffer[0..keep]);
                    if (keep < count) {
                        self.truncated = true;
                        self.cancelled = true;
                    }
                },
                .would_block => return,
                .eof => {
                    if (stream == 0) self.stdout_eof = true else self.stderr_eof = true;
                    return;
                },
            }
        }
    }
    /// Result slices live until deinit. Exit alone is not completion: both
    /// streams must reach EOF and the original process ownership must release.
    pub fn poll(self: *Command) !Result {
        const process = self.process orelse return error.CommandReleased;
        if (self.cleanup == .released) return self.snapshot();
        try self.drain(0);
        try self.drain(1);
        self.exit = try native.pollExit(process);
        if (self.limits.timeout_ms != 0 and native.zw_local_monotonic_ms() - self.started_ms >= self.limits.timeout_ms) {
            self.timed_out = true;
            self.cancelled = true;
        }
        if (self.cancelled or (self.exit != null and self.stdout_eof and self.stderr_eof)) self.cleanup = native.closeStep(process);
        if (self.cleanup == .released) self.exit = try native.pollExit(process);
        return self.snapshot();
    }
    fn snapshot(self: *const Command) Result {
        return .{ .owner = self.owner, .call_id = self.call_id, .stdout = self.stdout.items, .stderr = self.stderr.items, .exit = self.exit, .cancelled = self.cancelled, .timed_out = self.timed_out, .truncated = self.truncated, .cleanup = self.cleanup };
    }
    pub fn deinit(self: *Command) !void {
        const process = self.process orelse return;
        if (self.cleanup != .released or native.zw_local_destroy(process) != 0) return error.CleanupIncomplete;
        self.process = null;
        self.stdout.deinit(self.allocator);
        self.stderr.deinit(self.allocator);
    }
};
