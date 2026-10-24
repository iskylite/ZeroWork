//! Versioned process/terminal engine boundary. Public hosts keep this opaque
//! service; the provider owns PTYs, subprocesses, workers and recordings.
const std = @import("std");
const host = @import("session_host.zig");
const identity = @import("identity.zig");
const operations = @import("operation.zig");
const terminal = @import("terminal_service.zig");
pub const ProcessExit = union(enum) { exited: u8, signal: u8 };
pub const Foreground = extern struct { pid: c_int, process_group: c_int, session_id: c_int, name: [64]u8 };
pub const ExecLimits = struct { capture_bytes: u32 = 64 * 1024, timeout_ms: u32 = 30_000 };
pub const RecordingOptions = struct { io: std.Io, log: @import("../config/config.zig").Log = .{}, directory: ?[]const u8 = null };
pub const ProcessSnapshot = struct {
    owner: identity.SessionHandle,
    state: enum { starting, running, exited, failed, closing, closed, cleanup_unknown },
    pid: ?i32,
    exit: ?ProcessExit,
    eof_seen: bool,
    cleanup: host.CloseReceipt,
    foreground: ?Foreground,
};
pub const CwdSnapshot = struct {
    owner: identity.SessionHandle,
    value: ?[]u8,
    source: enum { unknown, initial_directory, process },
    pub fn deinit(self: *CwdSnapshot, allocator: std.mem.Allocator) void {
        if (self.value) |value| allocator.free(value);
    }
};
pub const ExecRisk = struct {
    handle: ExecHandle,
    command: []u8,
    command_truncated: bool,
    pid: ?i32,
    state: enum { pending, running, cleanup_unknown },
};
pub const CloseRiskSnapshot = struct {
    owner: identity.SessionHandle,
    process_state: @FieldType(ProcessSnapshot, "state"),
    shell_pid: ?i32,
    foreground: ?Foreground,
    foreground_state: enum { idle_shell, task, not_running, unknown },
    observed_monotonic_ms: u64,
    active_exec: []ExecRisk,
    unknown: bool,
    pub fn deinit(self: *CloseRiskSnapshot, allocator: std.mem.Allocator) void {
        for (self.active_exec) |job| allocator.free(job.command);
        allocator.free(self.active_exec);
    }
};
pub const ExecHandle = struct { owner: identity.SessionHandle, operation: operations.OperationKey, call_id: u64 };
pub const ExecRequest = struct { operation: operations.OperationKey, call_id: u64, command: []const u8, cwd: ?[]const u8 = null, limits: ExecLimits = .{} };
pub const ExecSnapshot = struct {
    handle: ExecHandle,
    stdout: []u8,
    stderr: []u8,
    exit: ?ProcessExit,
    cancelled: bool,
    timed_out: bool,
    truncated: bool,
    cleanup: host.CloseReceipt,
    done: bool,
    pub fn deinit(self: *ExecSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    context: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        destroy: *const fn (*anyopaque) anyerror!void,
        adapter: *const fn (*anyopaque) host.Adapter,
        shutdownStep: *const fn (*anyopaque) host.CloseReceipt,
        drain: *const fn (*anyopaque, *host.SessionHost) anyerror!bool,
        retire: *const fn (*anyopaque, identity.SessionHandle) anyerror!void,
        processSnapshot: *const fn (*anyopaque, identity.SessionHandle) anyerror!ProcessSnapshot,
        cwdSnapshot: *const fn (*anyopaque, identity.SessionHandle, std.mem.Allocator) anyerror!CwdSnapshot,
        copyCwd: *const fn (*anyopaque, identity.SessionHandle, std.mem.Allocator) anyerror!?[]u8,
        closeRiskSnapshot: *const fn (*anyopaque, identity.SessionHandle, std.mem.Allocator) anyerror!CloseRiskSnapshot,
        terminalService: *const fn (*anyopaque, host.ServiceHandle) anyerror!terminal.Service,
        configureRecording: *const fn (*anyopaque, RecordingOptions) anyerror!void,
        applyRecordingRetention: *const fn (*anyopaque, u64, u16) void,
        readOutput: *const fn (*anyopaque, identity.SessionHandle, []u8) anyerror!terminal.Read,
        startExec: *const fn (*anyopaque, host.ServiceHandle, ExecRequest) anyerror!ExecHandle,
        cancelExec: *const fn (*anyopaque, ExecHandle) anyerror!void,
        retireExec: *const fn (*anyopaque, ExecHandle) anyerror!void,
        execSnapshot: *const fn (*anyopaque, ExecHandle, std.mem.Allocator) anyerror!ExecSnapshot,
    };
    pub fn deinit(self: *Service) !void {
        try self.vtable.destroy(self.context);
        self.allocator.destroy(self);
    }
    pub fn adapter(self: *Service) host.Adapter {
        return self.vtable.adapter(self.context);
    }
    pub fn shutdownStep(self: *Service) host.CloseReceipt {
        return self.vtable.shutdownStep(self.context);
    }
    pub fn drain(self: *Service, session_host: *host.SessionHost) anyerror!bool {
        return self.vtable.drain(self.context, session_host);
    }
    pub fn retire(self: *Service, owner: identity.SessionHandle) anyerror!void {
        return self.vtable.retire(self.context, owner);
    }
    pub fn processSnapshot(self: *Service, owner: identity.SessionHandle) anyerror!ProcessSnapshot {
        return self.vtable.processSnapshot(self.context, owner);
    }
    pub fn cwdSnapshot(self: *Service, owner: identity.SessionHandle, allocator: std.mem.Allocator) anyerror!CwdSnapshot {
        return self.vtable.cwdSnapshot(self.context, owner, allocator);
    }
    pub fn copyCwd(self: *Service, owner: identity.SessionHandle, allocator: std.mem.Allocator) anyerror!?[]u8 {
        return self.vtable.copyCwd(self.context, owner, allocator);
    }
    pub fn closeRiskSnapshot(self: *Service, owner: identity.SessionHandle, allocator: std.mem.Allocator) anyerror!CloseRiskSnapshot {
        return self.vtable.closeRiskSnapshot(self.context, owner, allocator);
    }
    pub fn terminalService(self: *Service, binding: host.ServiceHandle) anyerror!terminal.Service {
        return self.vtable.terminalService(self.context, binding);
    }
    pub fn configureRecording(self: *Service, options: RecordingOptions) anyerror!void {
        return self.vtable.configureRecording(self.context, options);
    }
    pub fn applyRecordingRetention(self: *Service, revision: u64, days: u16) void {
        return self.vtable.applyRecordingRetention(self.context, revision, days);
    }
    pub fn readOutput(self: *Service, owner: identity.SessionHandle, buffer: []u8) anyerror!terminal.Read {
        return self.vtable.readOutput(self.context, owner, buffer);
    }
    pub fn startExec(self: *Service, binding: host.ServiceHandle, request: ExecRequest) anyerror!ExecHandle {
        return self.vtable.startExec(self.context, binding, request);
    }
    pub fn cancelExec(self: *Service, handle: ExecHandle) anyerror!void {
        return self.vtable.cancelExec(self.context, handle);
    }
    pub fn retireExec(self: *Service, handle: ExecHandle) anyerror!void {
        return self.vtable.retireExec(self.context, handle);
    }
    pub fn execSnapshot(self: *Service, handle: ExecHandle, allocator: std.mem.Allocator) anyerror!ExecSnapshot {
        return self.vtable.execSnapshot(self.context, handle, allocator);
    }
    pub fn bind(service_allocator: std.mem.Allocator, implementation: anytype) !*Service {
        const Engine = @typeInfo(@TypeOf(implementation)).pointer.child;
        const Forward = struct {
            fn get(raw: *anyopaque) *Engine {
                return @ptrCast(@alignCast(raw));
            }
            fn destroy(raw: *anyopaque) !void {
                return get(raw).deinit();
            }
            fn adapter(raw: *anyopaque) host.Adapter {
                return get(raw).adapter();
            }
            fn shutdownStep(raw: *anyopaque) host.CloseReceipt {
                return get(raw).shutdownStep();
            }
            fn drain(raw: *anyopaque, session_host: *host.SessionHost) anyerror!bool {
                return get(raw).drain(session_host);
            }
            fn retire(raw: *anyopaque, owner: identity.SessionHandle) anyerror!void {
                return get(raw).retire(owner);
            }
            fn processSnapshot(raw: *anyopaque, owner: identity.SessionHandle) anyerror!ProcessSnapshot {
                return get(raw).processSnapshot(owner);
            }
            fn cwdSnapshot(raw: *anyopaque, owner: identity.SessionHandle, allocator: std.mem.Allocator) anyerror!CwdSnapshot {
                return get(raw).cwdSnapshot(owner, allocator);
            }
            fn copyCwd(raw: *anyopaque, owner: identity.SessionHandle, allocator: std.mem.Allocator) anyerror!?[]u8 {
                return get(raw).copyCwd(owner, allocator);
            }
            fn closeRiskSnapshot(raw: *anyopaque, owner: identity.SessionHandle, allocator: std.mem.Allocator) anyerror!CloseRiskSnapshot {
                return get(raw).closeRiskSnapshot(owner, allocator);
            }
            fn terminalService(raw: *anyopaque, binding: host.ServiceHandle) anyerror!terminal.Service {
                return get(raw).terminalService(binding);
            }
            fn configureRecording(raw: *anyopaque, options: RecordingOptions) anyerror!void {
                return get(raw).configureRecording(options);
            }
            fn applyRecordingRetention(raw: *anyopaque, revision: u64, days: u16) void {
                return get(raw).applyRecordingRetention(revision, days);
            }
            fn readOutput(raw: *anyopaque, owner: identity.SessionHandle, buffer: []u8) anyerror!terminal.Read {
                return get(raw).readOutput(owner, buffer);
            }
            fn startExec(raw: *anyopaque, binding: host.ServiceHandle, request: ExecRequest) anyerror!ExecHandle {
                return get(raw).startExec(binding, request);
            }
            fn cancelExec(raw: *anyopaque, handle: ExecHandle) anyerror!void {
                return get(raw).cancelExec(handle);
            }
            fn retireExec(raw: *anyopaque, handle: ExecHandle) anyerror!void {
                return get(raw).retireExec(handle);
            }
            fn execSnapshot(raw: *anyopaque, handle: ExecHandle, allocator: std.mem.Allocator) anyerror!ExecSnapshot {
                return get(raw).execSnapshot(handle, allocator);
            }
            const vtable: VTable = .{ .destroy = @This().destroy, .adapter = @This().adapter, .shutdownStep = @This().shutdownStep, .drain = @This().drain, .retire = @This().retire, .processSnapshot = @This().processSnapshot, .cwdSnapshot = @This().cwdSnapshot, .copyCwd = @This().copyCwd, .closeRiskSnapshot = @This().closeRiskSnapshot, .terminalService = @This().terminalService, .configureRecording = @This().configureRecording, .applyRecordingRetention = @This().applyRecordingRetention, .readOutput = @This().readOutput, .startExec = @This().startExec, .cancelExec = @This().cancelExec, .retireExec = @This().retireExec, .execSnapshot = @This().execSnapshot };
        };
        const self = try service_allocator.create(Service);
        self.* = .{ .allocator = service_allocator, .context = implementation, .vtable = &Forward.vtable };
        return self;
    }
};
