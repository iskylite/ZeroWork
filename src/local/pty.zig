//! Fixed macOS zsh PTY foundation. It owns no widgets or HostConfig.
//! A later Local adapter drives reads/cleanup and publishes the original key.
const std = @import("std");
const identity = @import("../host/identity.zig");
const operation = @import("../host/operation.zig");
pub const native = @import("native.zig");
pub const Failure = native.Failure;
pub const Read = native.Read;
pub const Write = native.Write;
pub const Exit = native.Exit;
pub const Cleanup = native.Cleanup;
pub const Options = struct { initial_cwd: ?[]const u8 = null, term: []const u8 = "xterm-256color", cols: u16 = 80, rows: u16 = 24, bootstrap: ?[*:0]const u8 = null };

pub const Session = struct {
    owner: identity.SessionHandle,
    create_operation: operation.OperationKey,
    process: ?*native.Process,
    geometry_revision: u64 = 1,
    closing: bool = false,
    cleanup: Cleanup = .awaiting,

    pub fn start(allocator: std.mem.Allocator, owner: identity.SessionHandle, key: operation.OperationKey, options: Options, failure: *Failure) !Session {
        try native.validateOwner(owner, key);
        if (options.cols == 0 or options.rows == 0 or options.term.len == 0 or options.term.len > 128) return error.InvalidTerminalDefaults;
        try native.validateString(options.term);
        const cwd = try native.cwdZ(allocator, options.initial_cwd);
        defer if (cwd) |value| allocator.free(value);
        const term = try allocator.dupeSentinel(u8, options.term, 0);
        defer allocator.free(term);
        const process = native.zw_local_start_pty_edit(if (cwd) |value| value.ptr else null, term.ptr, options.cols, options.rows, options.bootstrap, failure) orelse return error.StartFailed;
        return .{ .owner = owner, .create_operation = key, .process = process };
    }
    fn current(self: *const Session, owner: identity.SessionHandle) !*native.Process {
        if (!self.owner.eql(owner)) return error.StaleSession;
        return self.process orelse error.SessionReleased;
    }
    pub fn readOutput(self: *Session, owner: identity.SessionHandle, buffer: []u8) !Read {
        return native.read(try self.current(owner), 0, buffer);
    }
    /// Partial writes consume only the returned count; caller keeps the rest.
    pub fn write(self: *Session, owner: identity.SessionHandle, bytes: []const u8) !Write {
        const process = try self.current(owner);
        if (self.closing) return error.SessionClosing;
        var count: usize = 0;
        return switch (native.zw_local_write(process, bytes.ptr, bytes.len, &count)) {
            0 => .would_block,
            1 => .{ .bytes = count },
            else => error.WriteFailed,
        };
    }
    pub fn resize(self: *Session, owner: identity.SessionHandle, revision: u64, cols: u16, rows: u16) !void {
        const process = try self.current(owner);
        if (self.closing) return error.SessionClosing;
        if (revision <= self.geometry_revision) return error.StaleGeometry;
        if (cols == 0 or rows == 0) return error.InvalidGeometry;
        if (native.zw_local_resize(process, cols, rows) != 0) return error.ResizeFailed;
        self.geometry_revision = revision;
    }
    pub fn dimensions(self: *const Session) !struct { cols: u16, rows: u16 } {
        var cols: u16 = 0;
        var rows: u16 = 0;
        if (native.zw_local_dimensions(self.process orelse return error.SessionReleased, &cols, &rows) != 0) return error.ResizeFailed;
        return .{ .cols = cols, .rows = rows };
    }
    pub fn pid(self: *const Session) !i32 {
        return native.zw_local_pid(self.process orelse return error.SessionReleased);
    }
    pub fn initialCwd(self: *const Session) ![]const u8 {
        return std.mem.span(native.zw_local_initial_cwd(self.process orelse return error.SessionReleased));
    }
    pub fn currentCwd(self: *const Session, allocator: std.mem.Allocator) !?[]u8 {
        var buffer: [4096]u8 = undefined;
        if (native.zw_local_cwd(self.process orelse return error.SessionReleased, &buffer, buffer.len) == 0) return null;
        return try allocator.dupe(u8, std.mem.sliceTo(&buffer, 0));
    }
    pub fn foreground(self: *const Session) ?native.Foreground {
        var value: native.Foreground = undefined;
        return if (native.zw_local_foreground(self.process orelse return null, &value) != 0) value else null;
    }
    pub fn pollExit(self: *Session) !?Exit {
        return native.pollExit(self.process orelse return error.SessionReleased);
    }
    /// Only the owning controller may enter this after the user accepts any
    /// required confirmation. Output remains readable until its separate EOF.
    pub fn closeStep(self: *Session, owner: identity.SessionHandle) !Cleanup {
        const process = try self.current(owner);
        self.closing = true;
        self.cleanup = native.closeStep(process);
        return self.cleanup;
    }
    pub fn deinit(self: *Session) !void {
        const process = self.process orelse return;
        if (self.cleanup != .released or native.zw_local_destroy(process) != 0) return error.CleanupIncomplete;
        self.process = null;
    }
};
