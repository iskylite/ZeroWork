//! SFTP domain lifecycle transaction. Adapter callbacks only enqueue/mark;
//! all domain publications, resource hooks and presentation run on safeTick.
const std = @import("std");
const domain = @import("session_host.zig");
const files = @import("file_binding_host.zig");
const identity = @import("identity.zig");
const operations = @import("operation.zig");
const plugins = @import("plugin_registry.zig");
const Snapshot = @import("../ui/session_lifecycle.zig").Snapshot;
pub const readonly = files.readonly;
pub const Bindings = struct { directory: domain.ServiceHandle, file_read: domain.ServiceHandle, transfer: domain.ServiceHandle };
pub const InitialDirectory = struct {
    endpoint: readonly.EndpointRef,
    key: operations.OperationKey,
    request_id: u64,
    directory_revision: u64,
    requested_path: []const u8,
    resolved_path: ?[]const u8,
    entries: []const readonly.Entry,
    failure: ?readonly.Failure = null,
    cleanup: readonly.ReleaseReceipt = .released,
    retired: bool = true,
};
pub const TransferStart = struct { source: files.Source, binding: domain.ServiceHandle };
pub const TransferClose = struct { owner: identity.SessionHandle, create_key: operations.OperationKey, operation: operations.OperationKey, binding: domain.ServiceHandle };
pub const TransferStatus = union(enum) { pending, ready: domain.ServiceHandle, failed: operations.Failure };
pub const TransferHooks = struct {
    context: *anyopaque,
    /// Enqueue the real backend; no IO here. Source is borrowed until close
    /// releases. An error must leave no accepted/retained backend resource.
    start: *const fn (*anyopaque, TransferStart) anyerror!void,
    /// Ready must be the exact reserved handle, backed by actual initialized
    /// transfer capability. A descriptor/registration alone cannot return ready.
    poll: *const fn (*anyopaque, domain.ServiceHandle, operations.OperationKey) TransferStatus,
    /// Nonblocking actual receipt, including not-started/prepare-failed cases.
    close: *const fn (*anyopaque, TransferClose) domain.CloseReceipt,
};
pub const Presentation = struct { owner: identity.SessionHandle, create_key: operations.OperationKey, target: domain.AttachmentTarget, handles: Bindings, initial_directory: InitialDirectory };
pub const PresentationHooks = struct {
    context: *anyopaque,
    /// Install the real file tab in this original target, copying borrowed
    /// directory data synchronously. Error means no attachment was installed;
    /// any accepted rollback resources must be owned until rollback releases.
    /// Hooks never call mutating SessionHost APIs reentrantly.
    install: *const fn (*anyopaque, Presentation) anyerror!domain.Attachment,
    /// Rollback/close this exact original attachment. Idempotent; no tab lookup
    /// by focus. Called only after protocol resources actually release.
    release: *const fn (*anyopaque, identity.SessionHandle, domain.Attachment, operations.OperationKey) domain.CloseReceipt,
    /// An install error may retain accepted local requests before attachment.
    /// Null is valid only when such an error retains no presentation resource.
    rollback: ?*const fn (*anyopaque, identity.SessionHandle, operations.OperationKey) domain.CloseReceipt = null,
};
pub const PathHook = struct { context: *anyopaque, get: *const fn (*anyopaque, domain.CreateRequest) anyerror![]const u8 };
pub const Options = struct { initial_path: ?PathHook = null };
const Stage = enum { queued, file_open, realpath, listing, transfer_open, publish_ready, presenting, attaching, attached, draining, closed };
const Entry = struct {
    request: Snapshot(domain.CreateRequest),
    arena: std.heap.ArenaAllocator,
    stage: Stage = .queued,
    handles: ?Bindings = null,
    endpoint: ?readonly.EndpointRef = null,
    file_attempted: bool = false,
    requested_path: []const u8 = ".",
    resolved_path: ?[]const u8 = null,
    entries: std.ArrayList(readonly.Entry) = .empty,
    directory_key: ?operations.OperationKey = null,
    buffered_response: ?files.Response = null,
    directory_final: bool = false,
    directory_retired: bool = false,
    directory_failure: ?readonly.Failure = null,
    next_page: u32 = 0,
    transfer_key: ?operations.OperationKey = null,
    transfer_attempted: bool = false,
    transfer_open_terminal: bool = false,
    transfer_cleanup_published: bool = false,
    attachment: ?domain.Attachment = null,
    presentation_attempted: bool = false,
    presentation_released: bool = false,
    cancel_requested: bool = false,
    close_key: ?operations.OperationKey = null,
    failure: ?operations.Failure = null,
    failure_published: bool = false,
    cleanup: domain.CloseReceipt = .awaiting,
    create_receipt: ?domain.CloseReceipt = null,
    close_receipt: ?domain.CloseReceipt = null,

    fn initial(self: *Entry) InitialDirectory {
        return .{ .endpoint = self.endpoint.?, .key = self.directory_key.?, .request_id = self.directory_key.?.operation_id, .directory_revision = 1, .requested_path = self.requested_path, .resolved_path = self.resolved_path, .entries = if (self.directory_failure == null) self.entries.items else &.{}, .failure = self.directory_failure };
    }
};

pub const SftpAdapter = struct {
    allocator: std.mem.Allocator,
    transfer: TransferHooks,
    presentation: PresentationHooks,
    options: Options,
    entries: std.ArrayList(*Entry) = .empty,
    host: ?*domain.SessionHost = null,
    file_host: ?*files.FileBindingHost = null,
    ticking: bool = false,

    pub fn init(allocator: std.mem.Allocator, transfer: TransferHooks, presentation: PresentationHooks, options: Options) !*SftpAdapter {
        const self = try allocator.create(SftpAdapter);
        self.* = .{ .allocator = allocator, .transfer = transfer, .presentation = presentation, .options = options };
        return self;
    }
    pub fn adapter(self: *SftpAdapter) domain.Adapter {
        return .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = releaseStale } };
    }
    pub fn deinit(self: *SftpAdapter) error{Busy}!void {
        for (self.entries.items) |entry| if (entry.stage != .closed or entry.cleanup != .released) return error.Busy;
        for (self.entries.items) |entry| self.destroy(entry);
        self.entries.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    pub fn retire(self: *SftpAdapter, owner: identity.SessionHandle) !void {
        for (self.entries.items, 0..) |entry, index| if (entry.request.value.handle.eql(owner)) {
            if (entry.stage != .closed or entry.cleanup != .released) return error.Busy;
            if (self.host) |host| if (host.queryState(owner)) |state| if (state.lifecycle != .closed and !(state.lifecycle == .failed and state.create_cleanup == .released)) return error.SessionStillPresented;
            _ = self.entries.orderedRemove(index);
            self.destroy(entry);
            return;
        };
        return error.StaleSession;
    }
    pub fn shutdownStep(self: *SftpAdapter) domain.CloseReceipt {
        var receipt: domain.CloseReceipt = .released;
        for (self.entries.items) |entry| {
            entry.cancel_requested = true;
            receipt = combine(receipt, entry.cleanup);
        }
        return receipt;
    }
    pub fn safeTick(self: *SftpAdapter, host: *domain.SessionHost, file_host: *files.FileBindingHost) !bool {
        if (self.ticking) return error.ReentrantSftpTick;
        if (file_host.sessions != host or (self.host != null and self.host.? != host) or (self.file_host != null and self.file_host.? != file_host)) return error.HostChanged;
        self.host = host;
        self.file_host = file_host;
        self.ticking = true;
        defer self.ticking = false;
        _ = try file_host.safeTick();
        var active = false;
        for (self.entries.items) |entry| {
            if (entry.stage == .closed) continue;
            active = true;
            const request = entry.request.value;
            const state = host.queryState(request.handle);
            if (state == null or !state.?.create_operation.eql(request.key)) {
                entry.cancel_requested = true;
            } else {
                // close() only queued a key. Confirm it against the original
                // domain transaction before any resource hook can consume it.
                if (entry.close_key) |queued| {
                    if (state.?.close_operation == null or !state.?.close_operation.?.eql(queued)) entry.close_key = null;
                }
                if (state.?.close_operation) |key| {
                    if (entry.close_key == null) entry.close_key = key;
                }
                if (state.?.lifecycle == .failed or state.?.lifecycle == .closing or state.?.lifecycle == .closed or state.?.lifecycle == .cleanup_unknown) entry.cancel_requested = true;
                if (entry.cancel_requested and (state.?.lifecycle == .creating or state.?.lifecycle == .ready or state.?.lifecycle == .attached)) {
                    if (state.?.lifecycle == .attached) {
                        entry.close_key = try host.requestClose(request.handle, .{});
                    } else _ = try host.cancel(request.key);
                }
            }
            if (entry.cancel_requested or entry.failure != null) entry.stage = .draining;
            if (entry.stage != .queued and entry.stage != .draining and entry.stage != .attached and entry.endpoint != null) {
                if (file_host.state(entry.handles.?.directory)) |physical| {
                    if (physical.phase == .failed or physical.phase == .closing or physical.phase == .cleanup_unknown or physical.phase == .closed) try self.recordFailure(entry, failure("sftp_connection_failed"));
                } else try self.recordFailure(entry, failure("sftp_binding_closed"));
            }
            if (entry.failure != null) entry.stage = .draining;
            if (entry.stage == .draining) {
                try self.drain(entry);
                continue;
            }
            self.advance(entry) catch |err| {
                if (err == error.OutOfMemory) return err;
                try self.recordFailure(entry, failure(@errorName(err)));
                entry.stage = .draining;
            };
        }
        return active;
    }

    fn advance(self: *SftpAdapter, entry: *Entry) !void {
        const host = self.host.?;
        const file_host = self.file_host.?;
        const request = entry.request.value;
        switch (entry.stage) {
            .queued => {
                // The standalone SFTP workspace never silently bypasses route.
                if (request.spec.saved.route_snapshot.len != 0) return error.ProxyJumpTransportUnavailable;
                const path = if (self.options.initial_path) |hook| try hook.get(hook.context, request) else ".";
                if (path.len == 0 or path.len > readonly.path_limit or std.mem.indexOfScalar(u8, path, 0) != null or (path[0] != '/' and !std.mem.eql(u8, path, "."))) return error.InvalidInitialDirectory;
                entry.requested_path = try entry.arena.allocator().dupe(u8, path);
                entry.handles = .{
                    .directory = try host.reserveService(request.handle, request.key, .directory),
                    .file_read = try host.reserveService(request.handle, request.key, .file_read),
                    .transfer = try host.reserveService(request.handle, request.key, .transfer),
                };
                entry.file_attempted = true;
                const handles = entry.handles.?;
                entry.endpoint = try file_host.attachPreparing(request.handle, request.key, .{ .directory = handles.directory, .file_read = handles.file_read });
                entry.stage = .file_open;
            },
            .file_open => {
                const physical = file_host.state(entry.handles.?.directory) orelse return error.FileBindingClosed;
                if (physical.phase != .ready) return;
                entry.directory_key = try file_host.beginPreparing(entry.handles.?.directory, request.key, .{ .path = entry.requested_path, .action = .realpath, .directory_revision = 1 });
                entry.stage = .realpath;
            },
            .realpath, .listing => try self.directory(entry),
            .transfer_open => {
                if (entry.transfer_key == null) entry.transfer_key = try host.journal.begin(.{ .session = request.handle }, request.key.attempt_id);
                if (!entry.transfer_attempted) {
                    try self.transfer.start(self.transfer.context, .{ .source = .{ .owner = request.handle, .create_key = request.key, .open_key = entry.transfer_key.?, .spec = request.spec }, .binding = entry.handles.?.transfer });
                    entry.transfer_attempted = true;
                }
                switch (self.transfer.poll(self.transfer.context, entry.handles.?.transfer, request.key)) {
                    .pending => {},
                    .failed => |value| try self.recordFailure(entry, value),
                    .ready => |binding| {
                        if (!binding.eql(entry.handles.?.transfer)) return error.TransferBindingMismatch;
                        _ = try host.journal.publish(entry.transfer_key.?, .completed, "sftp transfer backend ready", null);
                        entry.transfer_open_terminal = true;
                        entry.stage = .publish_ready;
                    },
                }
            },
            .publish_ready => {
                if (!entry.directory_retired or !entry.transfer_open_terminal) return error.StartupNotVerified;
                _ = try host.ready(request.handle, request.key, plugins.requiredServices(.sftp));
                const state = host.queryState(request.handle) orelse return error.StaleSession;
                if (state.lifecycle != .ready) return error.ReadyRejected;
                entry.stage = .presenting;
            },
            .presenting => {
                // A failed installer may own pending rollback resources. In
                // particular OOM must not retry it and duplicate those owners.
                if (entry.presentation_attempted) return error.PresentationInstallFailed;
                entry.presentation_attempted = true;
                entry.attachment = self.presentation.install(self.presentation.context, .{ .owner = request.handle, .create_key = request.key, .target = request.target, .handles = entry.handles.?, .initial_directory = entry.initial() }) catch |err| {
                    try self.recordFailure(entry, failure(@errorName(err)));
                    return;
                };
                if (!std.meta.eql(entry.attachment.?.target, request.target) or @backingInt(entry.attachment.?.tab_id) == 0) return error.InvalidPresentationAttachment;
                entry.stage = .attaching;
            },
            .attaching => {
                if (!try host.attached(request.handle, entry.attachment.?)) return error.AttachmentRejected;
                entry.stage = .attached;
            },
            .attached => {},
            .draining, .closed => unreachable,
        }
    }
    fn directory(self: *SftpAdapter, entry: *Entry) !void {
        const file_host = self.file_host.?;
        const key = entry.directory_key.?;
        for (0..8) |_| {
            if (entry.buffered_response == null) entry.buffered_response = file_host.take(key);
            const response = if (entry.buffered_response) |*value| value else break;
            const value = response.result.value;
            if (response.stale or !value.endpoint.eql(entry.endpoint.?) or value.directory_revision != 1) return error.StaleDirectoryResult;
            switch (value.body) {
                .realpath => |path| {
                    if (entry.stage != .realpath or path.len == 0 or path[0] != '/') return error.InvalidDirectoryResult;
                    entry.resolved_path = try entry.arena.allocator().dupe(u8, path);
                },
                .page => |page| {
                    if (entry.stage != .listing or page.index != entry.next_page or entry.entries.items.len + page.entries.len > readonly.entry_limit) return error.InvalidDirectoryResult;
                    const copied = try entry.arena.allocator().alloc(readonly.Entry, page.entries.len);
                    for (page.entries, copied) |item, *copy| copy.* = try copyEntry(entry.arena.allocator(), item);
                    try entry.entries.ensureUnusedCapacity(entry.arena.allocator(), copied.len);
                    entry.entries.appendSliceAssumeCapacity(copied);
                    entry.next_page += 1;
                },
                .failure => |value_failure| entry.directory_failure = value_failure,
                .cancelled => return error.DirectoryCancelled,
                else => return error.InvalidDirectoryResult,
            }
            entry.directory_final = value.final;
            const cleanup = value.cleanup;
            response.deinit();
            entry.buffered_response = null;
            if (entry.directory_final) {
                if (cleanup != .released) return error.DirectoryCleanupIncomplete;
                break;
            }
        }
        if (!entry.directory_final) return;
        if (!entry.directory_retired) {
            try file_host.retire(key);
            entry.directory_retired = true;
        }
        if (entry.stage == .realpath and entry.directory_failure == null) {
            entry.directory_key = try file_host.beginPreparing(entry.handles.?.directory, entry.request.value.key, .{ .path = entry.resolved_path.?, .action = .{ .list = .{} }, .directory_revision = 1 });
            entry.directory_final = false;
            entry.directory_retired = false;
            entry.stage = .listing;
        } else entry.stage = .transfer_open;
    }
    fn recordFailure(self: *SftpAdapter, entry: *Entry, value: operations.Failure) !void {
        _ = self;
        if (entry.failure != null) return;
        const a = entry.arena.allocator();
        var copy = value;
        copy.code = try a.dupe(u8, value.code);
        copy.safe_message = try a.dupe(u8, value.safe_message);
        copy.stage = if (value.stage) |stage| try a.dupe(u8, stage) else null;
        copy.cleanup = .releasing;
        entry.failure = copy;
    }
    fn drain(self: *SftpAdapter, entry: *Entry) !void {
        const host = self.host.?;
        const file_host = self.file_host.?;
        const request = entry.request.value;
        if (entry.failure) |value| if (!entry.failure_published) {
            _ = try host.failed(request.handle, request.key, value);
            entry.failure_published = true;
        };
        var file_receipt: domain.CloseReceipt = .released;
        if (entry.file_attempted) {
            const current = host.queryState(request.handle);
            if (current != null and current.?.create_operation.eql(request.key)) {
                const receipt = if (entry.close_key) |key| try file_host.requestClose(request.handle, key) else try file_host.cancelPreparing(request.handle, request.key);
                file_receipt = convert(receipt);
            } else if (entry.handles) |handles| if (file_host.state(handles.directory)) |physical| {
                // FileBindingHost.safeTick already closed this stale original
                // binding. Observe its real receipt without authorizing a new
                // generation through an invalid old domain handle.
                file_receipt = convert(physical.cleanup);
            };
        }
        if (entry.directory_key) |key| if (!entry.directory_retired) {
            if (entry.buffered_response) |*response| {
                if (response.result.value.final) entry.directory_final = true;
                response.deinit();
                entry.buffered_response = null;
            }
            for (0..8) |_| {
                var response = file_host.take(key) orelse break;
                defer response.deinit();
                if (response.result.value.final) entry.directory_final = true;
            }
            if (entry.directory_final and file_host.cleanupReceipt(key) == .released) {
                try file_host.retire(key);
                entry.directory_retired = true;
            }
        };
        const transfer_receipt: domain.CloseReceipt = if (entry.handles) |handles| self.transfer.close(self.transfer.context, .{ .owner = request.handle, .create_key = request.key, .operation = entry.close_key orelse request.key, .binding = handles.transfer }) else .released;
        if (entry.transfer_key) |key| {
            if (!entry.transfer_open_terminal) {
                if (entry.failure) |value| {
                    _ = try host.journal.publish(key, .failed, "", value);
                } else _ = try host.journal.publish(key, .cancelled, "sftp startup cancelled", null);
                entry.transfer_open_terminal = true;
            }
            if (transfer_receipt == .released and !entry.transfer_cleanup_published) {
                _ = try host.journal.publish(key, .cleanup_released, "sftp transfer backend released", null);
                entry.transfer_cleanup_published = true;
            }
        }
        var receipt = combine(file_receipt, transfer_receipt);
        if (entry.directory_key != null and !entry.directory_retired) receipt = combine(receipt, .awaiting);
        if (receipt == .released and entry.attachment != null and !entry.presentation_released) {
            receipt = self.presentation.release(self.presentation.context, request.handle, entry.attachment.?, entry.close_key orelse request.key);
            if (receipt == .released) entry.presentation_released = true;
        } else if (receipt == .released and entry.presentation_attempted and entry.attachment == null) {
            if (self.presentation.rollback) |rollback| receipt = rollback(self.presentation.context, request.handle, request.key);
        }
        entry.cleanup = receipt;
        if (entry.create_receipt == null or entry.create_receipt.? != receipt) {
            _ = try host.createCleanupReceipt(request.handle, request.key, receipt);
            entry.create_receipt = receipt;
        }
        if (entry.close_key) |key| if (entry.close_receipt == null or entry.close_receipt.? != receipt) {
            if (try host.closeReceipt(request.handle, key, .close_protocol, receipt)) entry.close_receipt = receipt;
        };
        if (receipt == .released) entry.stage = .closed;
    }

    fn find(self: *SftpAdapter, owner: identity.SessionHandle) ?*Entry {
        for (self.entries.items) |entry| if (entry.request.value.handle.eql(owner)) return entry;
        return null;
    }
    fn destroy(self: *SftpAdapter, entry: *Entry) void {
        if (entry.buffered_response) |*response| response.deinit();
        entry.request.deinit();
        entry.arena.deinit();
        self.allocator.destroy(entry);
    }
    fn create(raw: *anyopaque, request: domain.CreateRequest) !void {
        const self: *SftpAdapter = @ptrCast(@alignCast(raw));
        if (self.ticking) return error.ReentrantSftpCreate;
        if (request.spec.pluginId() != .sftp) return error.WrongPlugin;
        if (self.find(request.handle) != null) return error.DuplicateSession;
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        var owned = try Snapshot(domain.CreateRequest).init(self.allocator, request);
        errdefer owned.deinit();
        const entry = try self.allocator.create(Entry);
        entry.* = .{ .request = owned, .arena = .init(self.allocator) };
        self.entries.appendAssumeCapacity(entry);
    }
    fn cancel(raw: *anyopaque, key: operations.OperationKey) domain.CloseReceipt {
        const self: *SftpAdapter = @ptrCast(@alignCast(raw));
        if (key.owner != .session) return .unknown;
        const entry = self.find(key.owner.session) orelse return .unknown;
        if (!entry.request.value.key.eql(key)) return .unknown;
        if (entry.stage == .attached) return .unknown;
        entry.cancel_requested = true;
        return entry.cleanup;
    }
    fn close(raw: *anyopaque, owner: identity.SessionHandle, key: operations.OperationKey) !domain.CloseReceipt {
        const self: *SftpAdapter = @ptrCast(@alignCast(raw));
        const entry = self.find(owner) orelse return error.StaleSession;
        if (key.owner != .session or !key.owner.session.eql(owner)) return error.OwnerMismatch;
        if (entry.close_key) |previous| if (!previous.eql(key)) return error.StaleCloseOperation;
        entry.close_key = key;
        return entry.cleanup;
    }
    fn releaseStale(raw: *anyopaque, owner: identity.SessionHandle, key: operations.OperationKey) void {
        const self: *SftpAdapter = @ptrCast(@alignCast(raw));
        const entry = self.find(owner) orelse return;
        if (entry.request.value.key.eql(key)) entry.cancel_requested = true;
    }
};

fn copyEntry(a: std.mem.Allocator, entry: readonly.Entry) !readonly.Entry {
    return .{ .raw_name = try a.dupe(u8, entry.raw_name), .display_name = try a.dupe(u8, entry.display_name), .absolute_path = try a.dupe(u8, entry.absolute_path), .attributes = entry.attributes };
}
fn failure(code: []const u8) operations.Failure {
    return .{ .domain = .plugin, .code = code, .cleanup = .releasing, .safe_message = "SFTP 文件会话启动失败" };
}
fn combine(a: domain.CloseReceipt, b: domain.CloseReceipt) domain.CloseReceipt {
    if (a == .unknown or b == .unknown) return .unknown;
    if (a == .awaiting or b == .awaiting) return .awaiting;
    return .released;
}
fn convert(receipt: readonly.ReleaseReceipt) domain.CloseReceipt {
    return switch (receipt) {
        .released => .released,
        .awaiting => .awaiting,
        .unknown => .unknown,
    };
}
