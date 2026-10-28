//! SFTP mailbox on the original interactive Session's sole native IO owner.
//! Engine workers perform local file IO and exchange one bounded RPC at a
//! time. They never receive this Session, its fd, or a native SFTP handle.
const std = @import("std");
const ssh = @import("session.zig");
const c = @import("generated_ssh_session");
const transfer = @import("../../transfer/manager.zig");
const engine_mod = @import("../../transfer/sftp_engine.zig");
const identity = @import("../../host/identity.zig");
pub const readonly_mailbox = @import("shared_readonly_mailbox.zig");
const routing = @import("../../transfer/engine_mux.zig");

pub const Service = struct {
    allocator: std.mem.Allocator,
    session: *ssh.Session,
    backend: *engine_mod.SftpEngine,
    origin: ?identity.SessionHandle,
    binding: ?transfer.ServiceHandle = null,
    mutex: std.atomic.Value(bool) = .init(false),
    pending: ?*Request = null,
    readers: std.ArrayList(*readonly_mailbox.Mailbox) = .empty,
    readonly_retry: ?*readonly_mailbox.Mailbox = null,
    files: std.ArrayList(*File) = .empty,
    io_owner: ?std.Thread.Id = null,
    closing: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
    cleanup_unknown: std.atomic.Value(bool) = .init(false),
    routing_released: std.atomic.Value(bool) = .init(true),
    parent_released: std.atomic.Value(bool) = .init(false),
    faulted: std.atomic.Value(bool) = .init(false),
    would_block_count: std.atomic.Value(u64) = .init(0),
    read_bytes: std.atomic.Value(u64) = .init(0),
    written_bytes: std.atomic.Value(u64) = .init(0),

    const File = struct { native: ?ssh.SftpHandle, consumed: ?ssh.ReleaseReceipt = null };
    const Open = struct { path: [:0]const u8, kind: enum { read, write, append, exclusive }, offset: u64 = 0 };
    const Operation = union(enum) {
        stat: struct { path: [:0]const u8, follow: bool },
        open: Open,
        fstat: *File,
        read: struct { file: *File, bytes: []u8 },
        write: struct { file: *File, bytes: []const u8 },
        truncate: *File,
        close: *File,
        release_context,
    };
    const Result = union(enum) {
        success,
        attributes: ssh.SftpAttributes,
        file: *File,
        number: usize,
        close: ssh.SftpCloseResult,
        receipt: ssh.ReleaseReceipt,
        failure: anyerror,
    };
    const Request = struct {
        operation: Operation,
        deadline_ns: i128 = std.math.maxInt(i128),
        done: std.atomic.Value(bool) = .init(false),
        result: Result = .success,
        attributes: c.ZW_SFTP_ATTRIBUTES = undefined,
        opened_file: ?*File = null,
    };

    pub fn init(allocator: std.mem.Allocator, session: *ssh.Session) !*Service {
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        const backend = try engine_mod.SftpEngine.init(allocator);
        self.* = .{ .allocator = allocator, .session = session, .backend = backend, .origin = if (session.resource_key) |key| if (key.owner == .session) key.owner.session else null else null };
        backend.attachRemoteService(.{ .context = self, .size = size, .stat = stat, .target_stat = targetStat }, .{ .context = self, .open_read = openRead, .open_write = openWrite, .create_exclusive = createExclusive, .truncate = truncate, .stat_handle = fstat, .read = read, .write = write, .close = closeFile, .release = releaseContext });
        return self;
    }

    fn lock(self: *Service) void {
        while (self.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Service) void {
        self.mutex.store(false, .release);
    }

    pub fn bindService(self: *Service, binding: transfer.ServiceHandle) !void {
        if (self.mutex.swap(true, .acquire)) return error.WorkerBusy;
        defer self.unlock();
        if (self.closing.load(.acquire) or self.parent_released.load(.acquire) or self.faulted.load(.acquire)) return error.TransferServiceClosed;
        const origin = self.origin orelse return error.MissingOperation;
        if (binding.kind != .transfer or binding.binding_id == 0 or binding.binding_generation == 0 or binding.resource_owner != .session or !binding.resource_owner.session.eql(origin) or binding.origin_session == null or !binding.origin_session.?.eql(origin)) return error.InvalidTransferBinding;
        if (self.binding) |current| if (!current.eql(binding)) return error.StaleBinding;
        self.binding = binding;
        self.routing_released.store(false, .release);
    }

    pub fn readonlyProvider(self: *Service) readonly_mailbox.Provider {
        return .{ .context = self, .attach = attachReadonly };
    }
    fn attachReadonly(raw: *anyopaque, endpoint: readonly_mailbox.readonly.EndpointRef, key: readonly_mailbox.readonly.OperationKey) !*readonly_mailbox.Mailbox {
        const self = of(raw);
        self.lock();
        defer self.unlock();
        if (self.closing.load(.acquire) or self.parent_released.load(.acquire) or self.faulted.load(.acquire)) return error.TransferServiceClosed;
        const origin = self.origin orelse return error.MissingOperation;
        if (endpoint.resource_owner != .session or !endpoint.resource_owner.session.eql(origin) or endpoint.origin_session == null or !endpoint.origin_session.?.eql(origin)) return error.OwnerMismatch;
        for (self.readers.items) |reader| if (!reader.canReleaseParent()) return error.FileBindingBusy;
        while (self.readers.items.len != 0) {
            const old = self.readers.pop().?;
            old.destroy();
        }
        try self.readers.ensureUnusedCapacity(self.allocator, 1);
        const reader = try readonly_mailbox.Mailbox.init(self.allocator, endpoint, key);
        self.readers.appendAssumeCapacity(reader);
        return reader;
    }

    pub fn engine(self: *Service) transfer.TransferEngine {
        return .{ .ctx = self, .open = engineOpen, .poll = enginePoll, .cancel = engineCancel, .pause = enginePause, .resume_job = engineResume, .can_resume = engineCanResume, .conflict_snapshot = conflictSnapshot, .resolve_conflict = resolveConflict };
    }
    pub fn cleanupGuard(self: *Service) routing.CleanupGuard {
        return .{ .context = self, .receipt = cleanup };
    }
    fn cleanup(raw: *anyopaque, binding: transfer.ServiceHandle) routing.ReleaseReceipt {
        const self: *Service = @ptrCast(@alignCast(raw));
        if (self.binding == null or !self.binding.?.eql(binding)) return .unknown;
        return switch (self.closeReceipt()) {
            .released => .released,
            .awaiting => .awaiting,
            .unknown => .unknown,
        };
    }
    fn engineOpen(raw: *anyopaque, spec: transfer.JobSpec) !transfer.EngineJobId {
        const self: *Service = @ptrCast(@alignCast(raw));
        self.lock();
        defer self.unlock();
        if (self.closing.load(.acquire) or self.parent_released.load(.acquire) or self.faulted.load(.acquire)) return error.TransferServiceClosed;
        const binding = self.binding orelse return error.UnboundService;
        if (spec.transfer_binding == null or !spec.transfer_binding.?.eql(binding) or spec.session_id != @backingInt(self.origin.?.session_id)) return error.StaleBinding;
        return self.backend.open(spec);
    }
    fn enginePoll(raw: *anyopaque) ?transfer.EngineProgress {
        return of(raw).backend.poll();
    }
    fn engineCancel(raw: *anyopaque, id: transfer.EngineJobId) void {
        of(raw).backend.cancel(id);
    }
    fn enginePause(raw: *anyopaque, id: transfer.EngineJobId) !void {
        return of(raw).backend.pause(id);
    }
    fn engineResume(raw: *anyopaque, id: transfer.EngineJobId) !transfer.EngineJobId {
        const self = of(raw);
        if (self.closing.load(.acquire) or self.parent_released.load(.acquire) or self.faulted.load(.acquire)) return error.TransferServiceClosed;
        return self.backend.resumeJob(id);
    }
    fn engineCanResume(raw: *anyopaque, id: transfer.EngineJobId) bool {
        const self = of(raw);
        return !self.closing.load(.acquire) and !self.parent_released.load(.acquire) and !self.faulted.load(.acquire) and self.backend.canResume(id);
    }
    fn conflictSnapshot(raw: *anyopaque, allocator: std.mem.Allocator, id: transfer.EngineJobId) !?transfer.Conflict.OwnedSnapshot {
        return of(raw).backend.conflictSnapshot(allocator, id);
    }
    fn resolveConflict(raw: *anyopaque, id: transfer.EngineJobId, request: transfer.Conflict.Request) !void {
        return of(raw).backend.resolveConflict(id, request);
    }
    fn of(raw: *anyopaque) *Service {
        return @ptrCast(@alignCast(raw));
    }
    fn context(raw: ?*anyopaque) *Service {
        return of(raw.?);
    }
    fn file(value: *ssh.SftpHandle) *File {
        return @ptrCast(@alignCast(value.handle));
    }
    fn token(value: *File) ssh.SftpHandle {
        return .{ .handle = @ptrCast(value) };
    }

    fn call(self: *Service, operation: Operation) !Result {
        var request: Request = .{ .operation = operation, .deadline_ns = @import("../../platform/realtime.zig").monotonicNs() + 30 * std.time.ns_per_s };
        self.lock();
        if (self.parent_released.load(.acquire)) {
            self.unlock();
            return switch (operation) {
                .close => .{ .close = .{ .receipt = .released, .consumed = true } },
                .release_context => .{ .receipt = .released },
                else => error.TransferTransportClosed,
            };
        }
        if (self.pending != null) {
            self.unlock();
            return error.ConcurrentTransferRpc;
        }
        self.pending = &request;
        self.unlock();
        while (!request.done.load(.acquire)) {
            var wait: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
            _ = std.c.nanosleep(&wait, null);
        }
        return switch (request.result) {
            .failure => |err| err,
            else => request.result,
        };
    }
    fn size(raw: ?*anyopaque, _: *ssh.Session, path: [:0]const u8) !u64 {
        return (try context(raw).call(.{ .stat = .{ .path = path, .follow = true } })).attributes.size orelse error.MissingFileSize;
    }
    fn stat(raw: ?*anyopaque, _: *ssh.Session, path: [:0]const u8) !ssh.SftpAttributes {
        return (try context(raw).call(.{ .stat = .{ .path = path, .follow = true } })).attributes;
    }
    fn targetStat(raw: ?*anyopaque, _: *ssh.Session, path: [:0]const u8) !ssh.SftpAttributes {
        return (try context(raw).call(.{ .stat = .{ .path = path, .follow = false } })).attributes;
    }
    fn openRead(raw: ?*anyopaque, _: *ssh.Session, path: [:0]const u8, _: engine_mod.ReadPurpose) !ssh.SftpHandle {
        return token((try context(raw).call(.{ .open = .{ .path = path, .kind = .read } })).file);
    }
    fn openWrite(raw: ?*anyopaque, _: *ssh.Session, path: [:0]const u8, offset: u64, preserve: bool) !ssh.SftpHandle {
        return token((try context(raw).call(.{ .open = .{ .path = path, .kind = if (preserve or offset != 0) .append else .write, .offset = offset } })).file);
    }
    fn createExclusive(raw: ?*anyopaque, _: *ssh.Session, path: [:0]const u8) !ssh.SftpHandle {
        return token((try context(raw).call(.{ .open = .{ .path = path, .kind = .exclusive } })).file);
    }
    fn fstat(raw: ?*anyopaque, _: *ssh.Session, handle: *ssh.SftpHandle) !ssh.SftpAttributes {
        return (try context(raw).call(.{ .fstat = file(handle) })).attributes;
    }
    fn read(raw: ?*anyopaque, handle: *ssh.SftpHandle, bytes: []u8) !usize {
        return (try context(raw).call(.{ .read = .{ .file = file(handle), .bytes = bytes } })).number;
    }
    fn write(raw: ?*anyopaque, handle: *ssh.SftpHandle, bytes: []const u8) !usize {
        return (try context(raw).call(.{ .write = .{ .file = file(handle), .bytes = bytes } })).number;
    }
    fn truncate(raw: ?*anyopaque, _: *ssh.Session, handle: *ssh.SftpHandle) !void {
        _ = try context(raw).call(.{ .truncate = file(handle) });
    }
    fn closeFile(raw: ?*anyopaque, handle: *ssh.SftpHandle) ssh.SftpCloseResult {
        return (context(raw).call(.{ .close = file(handle) }) catch return .{ .receipt = .unknown, .consumed = false }).close;
    }
    fn releaseContext(raw: ?*anyopaque, _: *ssh.Session) ssh.ReleaseReceipt {
        return (context(raw).call(.release_context) catch return .unknown).receipt;
    }

    /// Called solely by SshWorker.step after interactive/exec IO. EAGAIN keeps
    /// this exact request and all arguments pinned, while PTY steps continue.
    pub fn step(self: *Service) !void {
        if (self.mutex.swap(true, .acquire)) return;
        defer self.unlock();
        const current = std.Thread.getCurrentId();
        if (self.io_owner) |owner| {
            if (owner != current) return error.WrongIoOwner;
        } else self.io_owner = current;
        // Never return borrowed RPC arguments while libssh2 may retain them.
        // Escalate to the transport owner, which settles the request only
        // after actual parent release through sessionReleased().
        const now = @import("../../platform/realtime.zig").monotonicNs();
        if (!self.faulted.load(.acquire)) {
            if (self.pending) |request| if (now >= request.deadline_ns) return error.SftpRequestTimeout;
            for (self.readers.items) |reader| if (reader.retryExpired(now)) return error.SftpRequestTimeout;
        }
        if (self.readonly_retry) |reader| {
            if (reader.step(self.session)) return;
            self.readonly_retry = null;
            return;
        }
        if (self.pending) |request| {
            if (request.operation == .release_context and !self.readersIdle()) {
                for (self.readers.items) |reader| if (reader.hasPending()) {
                    if (reader.step(self.session)) self.readonly_retry = reader;
                    break;
                };
                return;
            }
            const result = self.nativeStep(request) catch |err| switch (err) {
                error.WouldBlock, error.ChannelOpenBusy => {
                    _ = self.would_block_count.fetchAdd(1, .monotonic);
                    return;
                },
                else => Result{ .failure = err },
            };
            request.result = result;
            self.pending = null;
            request.done.store(true, .release);
        }
        for (self.readers.items) |reader| {
            if (reader.hasPending()) {
                if (reader.step(self.session)) self.readonly_retry = reader;
                break;
            }
        }
        if (self.closing.load(.acquire) and self.readersIdle() and self.backend.owner_done.load(.acquire) and self.backend.faultJobCount() == 0 and self.pending == null) {
            const receipt = if (self.parent_released.load(.acquire)) ssh.ReleaseReceipt.released else self.session.closeSftpReceipt();
            if (receipt == .released) self.released.store(true, .release);
            if (receipt == .unknown) self.cleanup_unknown.store(true, .release);
        }
    }

    fn attrs(raw: c.ZW_SFTP_ATTRIBUTES) ssh.SftpAttributes {
        const mode: u32 = @truncate(raw.permissions);
        return .{ .kind = if (raw.flags & 4 == 0) .unknown else switch (mode & 0o170000) {
            0o100000 => .file,
            0o040000 => .directory,
            0o120000 => .symlink,
            else => .other,
        }, .size = if (raw.flags & 1 != 0) raw.size else null, .modified_at = if (raw.flags & 8 != 0) raw.mtime else null, .permissions = if (raw.flags & 4 != 0) mode else null };
    }
    fn nativeError(self: *Service, code: anytype) anyerror {
        if (code == -37) return error.WouldBlock;
        if (code == -31 and self.session.sftp != null) return switch (c.zw_libssh2_sftp_status(self.session.sftp.?)) {
            2, 10 => error.FileNotFound,
            3 => error.PermissionDenied,
            8 => error.OperationUnsupported,
            11 => error.PathAlreadyExists,
            else => error.SftpProtocolFailed,
        };
        return error.SftpIoFailed;
    }
    fn nativeFile(value: *File) !*ssh.SftpHandle {
        if (value.consumed != null or value.native == null) return error.SftpHandleClosed;
        return &value.native.?;
    }
    fn nativeStep(self: *Service, request: *Request) !Result {
        if (request.operation != .release_context and request.operation != .close) try self.session.sftpReadonlyInit();
        switch (request.operation) {
            .stat => |op| {
                const rc = c.zw_libssh2_sftp_stat_attributes(self.session.sftp.?, op.path.ptr, @intFromBool(op.follow), &request.attributes);
                if (rc != 0) return self.nativeError(rc);
                return .{ .attributes = attrs(request.attributes) };
            },
            .open => |op| {
                // Reserve bookkeeping before the first native open. EAGAIN
                // retains this exact record; success cannot be lost to OOM.
                if (request.opened_file == null) {
                    try self.files.ensureUnusedCapacity(self.allocator, 1);
                    const value = try self.allocator.create(File);
                    value.* = .{ .native = null };
                    self.files.appendAssumeCapacity(value);
                    request.opened_file = value;
                }
                const native = switch (op.kind) {
                    .read => c.zw_libssh2_sftp_open_read(self.session.sftp.?, op.path.ptr),
                    .write => c.zw_libssh2_sftp_open_write(self.session.sftp.?, op.path.ptr),
                    .append => c.zw_libssh2_sftp_open_append(self.session.sftp.?, op.path.ptr, op.offset),
                    .exclusive => c.zw_libssh2_sftp_open_exclusive(self.session.sftp.?, op.path.ptr),
                };
                const handle = native orelse return self.nativeError(c.zw_libssh2_session_last_error(self.session.handle.?));
                const value = request.opened_file.?;
                value.native = .{ .handle = handle };
                return .{ .file = value };
            },
            .fstat => |value| {
                const handle = try nativeFile(value);
                const rc = c.zw_libssh2_sftp_fstat_attributes(handle.handle, &request.attributes);
                if (rc != 0) return self.nativeError(rc);
                return .{ .attributes = attrs(request.attributes) };
            },
            .read => |op| {
                const handle = try nativeFile(op.file);
                const count = c.zw_libssh2_sftp_read(handle.handle, op.bytes.ptr, op.bytes.len);
                if (count < 0) return self.nativeError(count);
                _ = self.read_bytes.fetchAdd(@intCast(count), .monotonic);
                return .{ .number = @intCast(count) };
            },
            .write => |op| {
                const handle = try nativeFile(op.file);
                const count = c.zw_libssh2_sftp_write(handle.handle, op.bytes.ptr, op.bytes.len);
                if (count < 0) return self.nativeError(count);
                // libssh2 may return zero after sending only part of an SFTP
                // packet: no payload has been acknowledged yet. Keep this RPC
                // and its arguments pinned, just as for native EAGAIN.
                if (count == 0 and op.bytes.len != 0) return error.WouldBlock;
                _ = self.written_bytes.fetchAdd(@intCast(count), .monotonic);
                return .{ .number = @intCast(count) };
            },
            .truncate => |value| {
                const handle = try nativeFile(value);
                const rc = c.zw_libssh2_sftp_truncate(handle.handle, 0);
                if (rc != 0) return self.nativeError(rc);
                return .success;
            },
            .close => |value| {
                if (value.consumed) |receipt| return .{ .close = .{ .receipt = receipt, .consumed = true } };
                const result = (try nativeFile(value)).closeReceipt();
                if (result.receipt == .awaiting) return error.WouldBlock;
                if (result.consumed) {
                    value.native = null;
                    value.consumed = result.receipt;
                }
                return .{ .close = result };
            },
            .release_context => {
                const receipt = self.session.closeSftpReceipt();
                if (receipt == .awaiting) return error.WouldBlock;
                if (receipt == .released) for (self.files.items) |value| {
                    value.native = null;
                    value.consumed = .released;
                };
                return .{ .receipt = receipt };
            },
        }
    }

    pub fn hasPending(self: *Service) bool {
        self.lock();
        defer self.unlock();
        for (self.readers.items) |reader| if (reader.hasPending()) return true;
        return !self.backend.owner_done.load(.acquire) or self.closing.load(.acquire) and !self.released.load(.acquire);
    }
    pub fn requestClose(self: *Service) void {
        self.closing.store(true, .release);
        self.backend.cancelAll();
        self.lock();
        defer self.unlock();
        for (self.readers.items) |reader| reader.requestClose();
    }
    pub fn closeReceipt(self: *Service) ssh.ReleaseReceipt {
        if (self.released.load(.acquire) or (self.parent_released.load(.acquire) and self.backend.owner_done.load(.acquire))) return .released;
        return if (self.cleanup_unknown.load(.acquire)) .unknown else .awaiting;
    }
    /// The controller acknowledges only after its exact Mux route detached.
    /// A released native parent alone cannot allow this same Service storage
    /// to be freed or rebound while an old router still retains its context.
    pub fn routingReleased(self: *Service, binding: transfer.ServiceHandle) !void {
        self.lock();
        defer self.unlock();
        if (self.binding == null or !self.binding.?.eql(binding)) return error.StaleBinding;
        if (self.closeReceipt() != .released or !self.backend.owner_done.load(.acquire) or self.backend.faultJobCount() != 0) return error.CleanupNotReleased;
        self.routing_released.store(true, .release);
    }
    fn readersIdle(self: *Service) bool {
        for (self.readers.items) |reader| if (reader.hasPending()) return false;
        return true;
    }
    pub fn canReleaseParent(self: *Service) bool {
        for (self.readers.items) |reader| if (!reader.canReleaseParent()) return false;
        return self.routing_released.load(.acquire) and self.backend.owner_done.load(.acquire) and self.backend.faultJobCount() == 0;
    }
    /// Native transport authority is already gone. This resolves native RPCs
    /// only after Session.closeReceipt really released the complete parent.
    pub fn sessionReleased(self: *Service) !void {
        if (self.session.state != .closed or self.session.handle != null) return error.CleanupNotReleased;
        self.lock();
        defer self.unlock();
        self.parent_released.store(true, .release);
        self.readonly_retry = null;
        for (self.readers.items) |reader| reader.sessionReleased();
        for (self.files.items) |value| {
            value.native = null;
            value.consumed = .released;
        }
        if (self.pending) |request| {
            request.result = switch (request.operation) {
                .close => .{ .close = .{ .receipt = .released, .consumed = true } },
                .release_context => .{ .receipt = .released },
                else => .{ .failure = error.TransferTransportClosed },
            };
            self.pending = null;
            request.done.store(true, .release);
        }
    }
    pub fn adoptIoAfterOwnerStopped(self: *Service) void {
        self.lock();
        defer self.unlock();
        self.io_owner = std.Thread.getCurrentId();
    }
    pub fn transportLost(self: *Service) void {
        self.faulted.store(true, .release);
        self.backend.transportFailed();
        self.lock();
        defer self.unlock();
        for (self.readers.items) |reader| reader.requestClose();
    }
    pub fn prepareReplacement(self: *Service) !void {
        if (!self.parent_released.load(.acquire) or !self.canReleaseParent()) return error.TransferCleanupPending;
    }
    pub fn transportReplaced(self: *Service) void {
        self.lock();
        defer self.unlock();
        self.binding = null;
        self.routing_released.store(true, .release);
        self.origin = if (self.session.resource_key) |key| if (key.owner == .session) key.owner.session else null else null;
        self.parent_released.store(false, .release);
        self.closing.store(false, .release);
        self.released.store(false, .release);
        self.cleanup_unknown.store(false, .release);
        self.faulted.store(false, .release);
        self.backend.attachRemoteService(.{ .context = self, .size = size, .stat = stat, .target_stat = targetStat }, .{ .context = self, .open_read = openRead, .open_write = openWrite, .create_exclusive = createExclusive, .truncate = truncate, .stat_handle = fstat, .read = read, .write = write, .close = closeFile, .release = releaseContext });
    }
    /// No native operations here. The old Session owner must have settled
    /// every accepted request and local checkpoint before its storage is freed.
    pub fn deinitLocal(self: *Service) !void {
        if (!self.canReleaseParent() or self.pending != null) return error.Busy;
        for (self.files.items) |value| if (value.native != null) return error.Busy;
        self.backend.deinit();
        for (self.readers.items) |reader| reader.destroy();
        self.readers.deinit(self.allocator);
        for (self.files.items) |value| {
            self.allocator.destroy(value);
        }
        self.files.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

test "shared transfer service binds only the original real transfer identity without IO" {
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(88), .generation = 3 };
    var session: ssh.Session = .{ .state = .active, .resource_key = .{ .owner = .{ .session = owner }, .operation_id = 9, .attempt_id = 1 } };
    const shared = try Service.init(std.testing.allocator, &session);
    const binding: transfer.ServiceHandle = .{ .kind = .transfer, .resource_owner = .{ .session = owner }, .origin_session = owner, .binding_id = 8, .binding_generation = 1 };
    defer {
        session.state = .closed;
        shared.sessionReleased() catch unreachable;
        shared.routingReleased(binding) catch unreachable;
        shared.deinitLocal() catch unreachable;
    }
    var wrong = binding;
    wrong.kind = .exec;
    try std.testing.expectError(error.InvalidTransferBinding, shared.bindService(wrong));
    try shared.bindService(binding);
    wrong = binding;
    wrong.binding_generation += 1;
    try std.testing.expectError(error.StaleBinding, shared.bindService(wrong));
    const api = shared.engine();
    try std.testing.expectError(error.StaleBinding, api.open(api.ctx, .{ .direction = .download, .sources = &.{"/never-read"}, .local_dir = "/never-created", .remote_dir = "/", .session_id = 88 }));
    try std.testing.expect(shared.backend.owner_done.load(.acquire));
    try std.testing.expect(shared.backend.service_token.handle == null and shared.backend.service_token.socket_fd == -1 and shared.backend.service_token.channel == null);
    try std.testing.expect(shared.io_owner == null and shared.pending == null);
    try std.testing.expect(!shared.canReleaseParent());
    try std.testing.expectError(error.CleanupNotReleased, shared.routingReleased(binding));
    shared.transportLost();
    try std.testing.expectError(error.TransferServiceClosed, shared.bindService(binding));
    try std.testing.expectError(error.TransferServiceClosed, api.open(api.ctx, .{ .direction = .download, .sources = &.{"/never-read"}, .local_dir = "/never-created", .remote_dir = "/", .session_id = 88, .transfer_binding = binding }));
    try std.testing.expect(!api.can_resume.?(api.ctx, 1));
}

test "shared transfer actual parent release resolves a pending RPC without borrowing a native Session" {
    var session: ssh.Session = .{ .state = .active };
    const shared = try Service.init(std.testing.allocator, &session);
    defer shared.deinitLocal() catch unreachable;
    var bytes: [4]u8 = undefined;
    var value: Service.File = .{ .native = null };
    var request: Service.Request = .{ .operation = .{ .read = .{ .file = &value, .bytes = &bytes } } };
    shared.pending = &request;
    try std.testing.expectError(error.CleanupNotReleased, shared.sessionReleased());
    try std.testing.expect(!request.done.load(.acquire));
    session.state = .closed;
    try shared.sessionReleased();
    try std.testing.expect(request.done.load(.acquire));
    try std.testing.expect(request.result == .failure and request.result.failure == error.TransferTransportClosed);
    try std.testing.expect(shared.pending == null);
    try std.testing.expectEqual(ssh.ReleaseReceipt.released, shared.closeReceipt());
    const close_result = try shared.call(.{ .close = &value });
    try std.testing.expect(close_result.close.consumed and close_result.close.receipt == .released);
    try std.testing.expectError(error.TransferTransportClosed, shared.call(.{ .read = .{ .file = &value, .bytes = &bytes } }));
}

test "shared transfer timeout keeps borrowed request pinned until actual parent release" {
    var session: ssh.Session = .{ .state = .active };
    const shared = try Service.init(std.testing.allocator, &session);
    defer shared.deinitLocal() catch unreachable;
    var bytes: [4]u8 = undefined;
    var value: Service.File = .{ .native = null };
    var request: Service.Request = .{ .operation = .{ .read = .{ .file = &value, .bytes = &bytes } }, .deadline_ns = 0 };
    shared.pending = &request;
    try std.testing.expectError(error.SftpRequestTimeout, shared.step());
    try std.testing.expect(shared.pending == &request);
    try std.testing.expect(!request.done.load(.acquire));
    session.state = .closed;
    try shared.sessionReleased();
    try std.testing.expect(request.done.load(.acquire));
    try std.testing.expectEqual(ssh.ReleaseReceipt.released, shared.closeReceipt());
}
