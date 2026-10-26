//! Controller-thread owner for independent remote-file connections. Domain
//! identities/operation keys come from SessionHost; no UI or worker retains it.
const std = @import("std");
const sessions = @import("session_host.zig");
const identity = @import("identity.zig");
const operations = @import("operation.zig");
const Snapshot = @import("../ui/session_lifecycle.zig").Snapshot;
pub const readonly = @import("../proto/ssh/sftp_readonly.zig");
const ssh = @import("../proto/ssh/session.zig");
const known = @import("../proto/ssh/host_key_store.zig");

pub const Source = struct {
    owner: identity.SessionHandle,
    retained_owner: ?identity.RetainedTransferOwnerId = null,
    create_key: operations.OperationKey,
    open_key: operations.OperationKey,
    spec: sessions.SessionCreateSpec,
    progress_observer: ?@import("../proto/ssh/connection_progress.zig").Observer = null,

    pub fn ownsOperation(self: Source, key: operations.OperationKey) bool {
        if (key.operation_id == 0) return false;
        const expected: identity.CommandOwner = if (self.retained_owner) |id| .{ .transfer_owner = .{ .id = id, .original_handle = self.owner } } else .{ .session = self.owner };
        return std.meta.eql(key.owner, expected);
    }
};
pub const Factory = struct {
    context: *anyopaque,
    /// Prepare owns memory only; connect runs later on readonly's worker.
    /// Source.spec borrows the host's immutable snapshot until actual close.
    prepare: *const fn (*anyopaque, Source) anyerror!readonly.Connector,
    /// Only a failed start calls discard, before any worker/native IO exists.
    discard: *const fn (*anyopaque, readonly.Connector) void,
};
pub const Bindings = struct {
    directory: sessions.ServiceHandle,
    file_read: sessions.ServiceHandle,
    fn eql(self: Bindings, other: Bindings) bool {
        return self.directory.eql(other.directory) and self.file_read.eql(other.file_read);
    }
};
pub const Call = struct { path: []const u8, action: readonly.Action, directory_revision: u64 = 0 };
pub const Phase = enum { connecting, ready, failed, closing, cleanup_unknown, closed };
pub const State = struct {
    owner: identity.SessionHandle,
    endpoint: readonly.EndpointRef,
    open_key: operations.OperationKey,
    phase: Phase,
    failure: ?readonly.Failure,
    cleanup: readonly.ReleaseReceipt,
};
pub const Response = struct {
    binding: sessions.ServiceHandle,
    stale: bool,
    result: readonly.OwnedResult,
    pub fn deinit(self: *Response) void {
        self.result.deinit();
    }
};
const SharedMailbox = @import("../proto/ssh/shared_readonly_mailbox.zig");
const Backend = union(enum) {
    dedicated: *readonly.Service,
    shared: *SharedMailbox.Mailbox,
    fn submit(self: Backend, key: operations.OperationKey, request: readonly.Request) !void {
        switch (self) {
            .dedicated => |service| try service.submit(key, request),
            .shared => |mailbox| try mailbox.submit(key, request),
        }
    }
    fn cancel(self: Backend, key: operations.OperationKey) bool {
        return switch (self) {
            .dedicated => |service| service.cancel(key),
            .shared => |mailbox| mailbox.cancel(key),
        };
    }
    fn poll(self: Backend) ?readonly.OwnedResult {
        return switch (self) {
            .dedicated => |service| service.poll(),
            .shared => |mailbox| mailbox.poll(),
        };
    }
    fn requestClose(self: Backend) void {
        switch (self) {
            .dedicated => |service| service.requestClose(),
            .shared => |mailbox| mailbox.requestClose(),
        }
    }
    fn closeReceipt(self: Backend) readonly.ReleaseReceipt {
        return switch (self) {
            .dedicated => |service| service.closeReceipt(),
            .shared => |mailbox| mailbox.closeReceipt(),
        };
    }
    fn deinit(self: Backend) !void {
        switch (self) {
            .dedicated => |service| try service.deinit(),
            .shared => |mailbox| try mailbox.deinit(),
        }
    }
};
const Binding = struct {
    owner: identity.SessionHandle,
    handles: Bindings,
    endpoint: readonly.EndpointRef,
    source: Snapshot(sessions.SessionCreateSpec),
    open_key: operations.OperationKey,
    startup_key: ?operations.OperationKey = null,
    auxiliary: ?sessions.AuxiliaryReadonlyStart = null,
    service: ?Backend = null,
    journal: @import("../proto/ssh/connection_progress.zig").Journal = .{},
    phase: Phase = .connecting,
    failure: ?readonly.Failure = null,
    cleanup: readonly.ReleaseReceipt = .awaiting,
    closing: bool = false,
    buffered: ?readonly.OwnedResult = null,
};
const Pending = struct {
    key: operations.OperationKey,
    endpoint: readonly.EndpointRef,
    binding: sessions.ServiceHandle,
    startup_key: ?operations.OperationKey = null,
    terminal: bool = false,
    cancel_requested: bool = false,
    cleanup: readonly.ReleaseReceipt = .awaiting,
    final_taken: bool = false,
};
const Diagnostic = struct { handle: sessions.ServiceHandle, failure: ?readonly.Failure, journal: @import("../proto/ssh/connection_progress.zig").Journal.Snapshot };
const binding_limit = 8;
const operation_limit = 64;
const response_limit = 64;

pub const FileBindingHost = struct {
    allocator: std.mem.Allocator,
    sessions: *sessions.SessionHost,
    factory: Factory,
    bindings: std.ArrayList(*Binding) = .empty,
    finished_diagnostics: std.ArrayList(Diagnostic) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    responses: std.ArrayList(Response) = .empty,

    pub fn init(allocator: std.mem.Allocator, host: *sessions.SessionHost, factory: Factory) !FileBindingHost {
        var self: FileBindingHost = .{ .allocator = allocator, .sessions = host, .factory = factory };
        try self.finished_diagnostics.ensureTotalCapacity(allocator, binding_limit);
        errdefer self.finished_diagnostics.deinit(allocator);
        try self.bindings.ensureTotalCapacity(allocator, binding_limit);
        errdefer self.bindings.deinit(allocator);
        try self.pending.ensureTotalCapacity(allocator, operation_limit);
        errdefer self.pending.deinit(allocator);
        try self.responses.ensureTotalCapacity(allocator, response_limit);
        return self;
    }

    /// Both logical handles must already be real live SessionHost services.
    /// The directory handle supplies the physical endpoint identity; file_read
    /// maps to it without allocating a parallel binding/session ID.
    pub fn attach(self: *FileBindingHost, owner: identity.SessionHandle, handles: Bindings) !readonly.EndpointRef {
        try self.validateHandles(owner, handles);
        return self.startBinding(owner, handles, null, null);
    }

    /// Explicit SSH file-source connection, with real domain-reserved handles.
    /// Ready is published only after this Service initializes native SFTP.
    pub fn attachAuxiliary(self: *FileBindingHost, owner: identity.SessionHandle, start: sessions.AuxiliaryReadonlyStart) !readonly.EndpointRef {
        if (!self.sessions.auxiliaryReadonlyOwns(owner, start) or !self.sessions.auxiliaryReadonlyIsCurrent(owner, start.key)) return error.StaleBinding;
        const handles: Bindings = .{ .directory = start.bindings.directory, .file_read = start.bindings.file_read };
        const endpoint = try self.startBinding(owner, handles, null, null);
        self.findEndpoint(endpoint).?.auxiliary = start;
        return endpoint;
    }

    pub fn attachShared(self: *FileBindingHost, owner: identity.SessionHandle, start: sessions.AuxiliaryReadonlyStart, provider: SharedMailbox.Provider) !readonly.EndpointRef {
        if (!self.sessions.auxiliaryReadonlyOwns(owner, start) or !self.sessions.auxiliaryReadonlyIsCurrent(owner, start.key)) return error.StaleBinding;
        const endpoint = try self.startBinding(owner, .{ .directory = start.bindings.directory, .file_read = start.bindings.file_read }, null, provider);
        self.findEndpoint(endpoint).?.auxiliary = start;
        return endpoint;
    }

    /// Adapter-only startup path. These are SessionHost-reserved identities,
    /// not live services. Ordinary attach/begin/submit keep their live gate.
    pub fn attachPreparing(self: *FileBindingHost, owner: identity.SessionHandle, create_key: operations.OperationKey, handles: Bindings) !readonly.EndpointRef {
        try self.validatePreparingHandles(owner, create_key, handles);
        return self.startBinding(owner, handles, create_key, null);
    }

    fn startBinding(self: *FileBindingHost, owner: identity.SessionHandle, handles: Bindings, startup_key: ?operations.OperationKey, provider: ?SharedMailbox.Provider) !readonly.EndpointRef {
        for (self.bindings.items) |binding| if (binding.owner.eql(owner)) {
            if (!binding.handles.eql(handles) or binding.closing) return error.FileBindingBusy;
            if (startup_key) |key| if (binding.startup_key == null or !binding.startup_key.?.eql(key)) return error.FileBindingBusy;
            return binding.endpoint;
        };
        if (self.bindings.items.len == binding_limit) return error.FileBindingLimit;
        const domain_state = self.sessions.queryState(owner) orelse return error.StaleSession;
        const spec = try self.savedSpec(owner);
        if (spec == .local) return error.UnsupportedProtocol;
        const binding = try self.allocator.create(Binding);
        errdefer self.allocator.destroy(binding);
        var source = try Snapshot(sessions.SessionCreateSpec).init(self.allocator, spec);
        errdefer source.deinit();
        const open_key = try self.sessions.journal.begin(.{ .session = owner }, domain_state.create_operation.attempt_id);
        errdefer self.rejected(open_key, "file_binding_start_rejected");
        const endpoint: readonly.EndpointRef = .{
            .binding_id = handles.directory.binding_id,
            .binding_generation = handles.directory.binding_generation,
            .resource_owner = .{ .session = owner },
            .origin_session = owner,
            .connection_snapshot_id = domain_state.create_operation.operation_id,
        };
        binding.* = .{ .owner = owner, .handles = handles, .endpoint = endpoint, .source = source, .open_key = open_key, .startup_key = startup_key };
        binding.journal.begin(open_key.attempt_id orelse 0);
        if (provider) |shared| {
            binding.service = .{ .shared = try shared.attach(shared.context, endpoint, open_key) };
        } else {
            const connector = try self.factory.prepare(self.factory.context, .{ .owner = owner, .create_key = domain_state.create_operation, .open_key = open_key, .spec = binding.source.value, .progress_observer = binding.journal.observer() });
            var transferred = false;
            errdefer if (!transferred) self.factory.discard(self.factory.context, connector);
            if (!connector.key.eql(open_key)) return error.FactoryOperationMismatch;
            binding.service = .{ .dedicated = try readonly.Service.start(self.allocator, endpoint, connector) };
            transferred = true;
        }
        self.bindings.appendAssumeCapacity(binding);
        return endpoint;
    }

    /// Allocates the key in the original SessionHost journal, never a private
    /// per-file counter. Request IDs use this same globally unique operation ID.
    pub fn begin(self: *FileBindingHost, binding: sessions.ServiceHandle, call: Call) !operations.OperationKey {
        const target = try self.resolve(binding, call.action);
        const domain_state = self.sessions.queryState(target.owner) orelse return error.StaleSession;
        const key = try self.sessions.journal.begin(.{ .session = target.owner }, domain_state.create_operation.attempt_id);
        self.submit(binding, key, call) catch |err| {
            self.rejected(key, @errorName(err));
            return err;
        };
        return key;
    }

    /// Only the original adapter startup can validate REALPATH/LIST/stat
    /// before domain.ready. FileRead and ordinary consumers remain unavailable.
    pub fn beginPreparing(self: *FileBindingHost, handle: sessions.ServiceHandle, create_key: operations.OperationKey, call: Call) !operations.OperationKey {
        if (call.action == .read_text or call.action == .mkdir) return error.StartupActionNotAllowed;
        if (handle.kind != .directory) return error.ServiceKindMismatch;
        const owner = switch (handle.resource_owner) {
            .session => |owner| owner,
            .retained_transfer => return error.OwnerMismatch,
        };
        const binding = self.findPreparing(owner, create_key) orelse return error.FileBindingNotPreparing;
        try self.validatePreparingHandles(owner, create_key, binding.handles);
        if (!binding.handles.directory.eql(handle)) return error.StaleBinding;
        if (binding.closing or binding.service == null) return error.FileServiceClosing;
        const key = try self.sessions.journal.begin(.{ .session = owner }, create_key.attempt_id);
        self.enqueue(binding, handle, key, call, create_key) catch |err| {
            self.rejected(key, @errorName(err));
            return err;
        };
        return key;
    }

    pub fn submit(self: *FileBindingHost, handle: sessions.ServiceHandle, key: operations.OperationKey, call: Call) !void {
        const binding = try self.resolve(handle, call.action);
        return self.enqueue(binding, handle, key, call, null);
    }

    fn enqueue(self: *FileBindingHost, binding: *Binding, handle: sessions.ServiceHandle, key: operations.OperationKey, call: Call, startup_key: ?operations.OperationKey) !void {
        try self.validateOperation(binding.owner, key);
        if (self.pending.items.len == operation_limit) return error.FileOperationLimit;
        for (self.pending.items) |pending| if (pending.key.eql(key)) return error.DuplicateOperation;
        const service = binding.service orelse return error.FileServiceClosed;
        try service.submit(key, .{ .endpoint = binding.endpoint, .request_id = key.operation_id, .directory_revision = call.directory_revision, .path = call.path, .action = call.action });
        self.pending.appendAssumeCapacity(.{ .key = key, .endpoint = binding.endpoint, .binding = handle, .startup_key = startup_key });
    }

    pub fn cancel(self: *FileBindingHost, key: operations.OperationKey) bool {
        const pending = self.findPending(key) orelse return false;
        if (pending.terminal) return false;
        const binding = self.findEndpoint(pending.endpoint) orelse return false;
        const service = binding.service orelse return false;
        const accepted = service.cancel(key);
        if (accepted) pending.cancel_requested = true;
        return accepted;
    }

    /// Call from ApplicationHost's controller-thread safe tick. Stale responses
    /// never deliver file content; terminal cancellation still returns its key
    /// and actual cleanup so a waiting tool can release its original exchange.
    pub fn safeTick(self: *FileBindingHost) !bool {
        var active = false;
        var index: usize = 0;
        while (index < self.bindings.items.len) {
            const binding = self.bindings.items[index];
            const service = binding.service.?;
            if (!self.current(binding)) self.closeBinding(binding);
            var drained = false;
            for (0..8) |_| {
                if (binding.buffered == null) binding.buffered = service.poll();
                if (binding.buffered == null) {
                    drained = true;
                    break;
                }
                if (!try self.receive(binding, &binding.buffered.?)) break;
                binding.buffered = null;
            }
            const receipt = service.closeReceipt();
            binding.cleanup = receipt;
            if (receipt == .unknown) {
                binding.phase = .cleanup_unknown;
                if (binding.auxiliary) |start| _ = try self.sessions.auxiliaryReadonlyReleased(binding.owner, start, .unknown);
                if (binding.startup_key) |key| _ = try self.sessions.sftpDirectoryRecoveryReleased(binding.handles.directory, key, .unknown);
            }
            if (receipt == .released) {
                try self.released(binding);
                if (drained and binding.buffered == null) {
                    if (binding.startup_key != null) {
                        if (self.finished_diagnostics.items.len == binding_limit) _ = self.finished_diagnostics.orderedRemove(0);
                        self.finished_diagnostics.appendAssumeCapacity(.{ .handle = binding.handles.directory, .failure = binding.failure, .journal = binding.journal.snapshot() });
                    }
                    try service.deinit();
                    binding.source.deinit();
                    _ = self.bindings.orderedRemove(index);
                    self.allocator.destroy(binding);
                    continue;
                }
            }
            active = true;
            index += 1;
        }
        return active;
    }

    pub fn take(self: *FileBindingHost, key: operations.OperationKey) ?Response {
        var index: usize = 0;
        while (index < self.responses.items.len) {
            const response = &self.responses.items[index];
            if (!response.result.value.key.eql(key)) {
                index += 1;
                continue;
            }
            const pending = self.findPending(key) orelse return null;
            // A result can be buffered before a close/reconnect and consumed
            // afterward. Revalidate at delivery as well as at worker drain.
            const stale = response.stale or !self.pendingCurrent(pending);
            if (stale or pending.cancel_requested) {
                if (!response.result.value.final) {
                    var discarded = self.responses.orderedRemove(index);
                    discarded.deinit();
                    continue;
                }
                response.stale = stale;
                if (response.result.value.body != .created) response.result.value.body = .cancelled;
            }
            const result = self.responses.orderedRemove(index);
            if (result.result.value.final) pending.final_taken = true;
            return result;
        }
        return null;
    }

    pub fn cleanupReceipt(self: *FileBindingHost, key: operations.OperationKey) readonly.ReleaseReceipt {
        return if (self.findPending(key)) |pending| pending.cleanup else .unknown;
    }

    /// Call after consuming the final response and actual cleanup. A retained
    /// unknown operation cannot be forgotten or inherited by a later attempt.
    pub fn retire(self: *FileBindingHost, key: operations.OperationKey) !void {
        for (self.pending.items, 0..) |pending, index| if (pending.key.eql(key)) {
            if (!pending.terminal or !pending.final_taken) return error.OperationPending;
            if (pending.cleanup != .released) return error.CleanupNotReleased;
            try self.sessions.journal.retire(key, .resources_released);
            _ = self.pending.orderedRemove(index);
            return;
        };
        return error.UnknownOperation;
    }

    pub fn osDetection(self: *FileBindingHost, owner: identity.SessionHandle) ?struct { kind: @import("../proto/ssh/remote_os.zig").Kind, source: sessions.SessionCreateSpec } {
        for (self.bindings.items) |binding| if (binding.owner.eql(owner) and !binding.closing) {
            const backend = binding.service orelse continue;
            const service = switch (backend) {
                .dedicated => |value| value,
                .shared => continue,
            };
            const kind = service.detected_os.load(.acquire);
            if (kind != .unknown) return .{ .kind = kind, .source = binding.source.value };
        };
        return null;
    }

    pub fn connectionFailure(self: *FileBindingHost, handle: sessions.ServiceHandle) ?readonly.Failure {
        for (self.bindings.items) |binding| if (binding.handles.directory.eql(handle)) return binding.failure;
        for (self.finished_diagnostics.items) |value| if (value.handle.eql(handle)) return value.failure;
        return null;
    }

    pub fn connectionJournal(self: *FileBindingHost, handle: sessions.ServiceHandle) ?@import("../proto/ssh/connection_progress.zig").Journal.Snapshot {
        for (self.bindings.items) |binding| if (binding.handles.directory.eql(handle)) return binding.journal.snapshot();
        for (self.finished_diagnostics.items) |value| if (value.handle.eql(handle)) return value.journal;
        return null;
    }

    pub fn state(self: *FileBindingHost, handle: sessions.ServiceHandle) ?State {
        for (self.bindings.items) |binding| if (binding.handles.directory.eql(handle) or binding.handles.file_read.eql(handle)) return .{
            .owner = binding.owner,
            .endpoint = binding.endpoint,
            .open_key = binding.open_key,
            .phase = binding.phase,
            .failure = binding.failure,
            .cleanup = binding.cleanup,
        };
        return null;
    }

    /// Reuse the caller's original domain close operation. This resource hook
    /// never completes that parent operation, which has other close steps.
    pub fn requestClose(self: *FileBindingHost, owner: identity.SessionHandle, key: operations.OperationKey) !readonly.ReleaseReceipt {
        const domain = self.sessions.queryState(owner) orelse return error.StaleSession;
        if (key.owner != .session or !key.owner.session.eql(owner) or domain.close_operation == null or !domain.close_operation.?.eql(key)) return error.StaleCloseOperation;
        for (self.bindings.items) |binding| if (binding.owner.eql(owner)) {
            self.closeBinding(binding);
            return binding.service.?.closeReceipt();
        };
        return .released;
    }

    /// Adapter.cancel uses its actual create operation, including after the
    /// domain has revoked reservations on failed/cancelled startup. No sibling
    /// or replacement generation is closed, and receipts stay native/async.
    pub fn cancelPreparing(self: *FileBindingHost, owner: identity.SessionHandle, create_key: operations.OperationKey) !readonly.ReleaseReceipt {
        const domain = self.sessions.queryState(owner) orelse return error.StaleSession;
        if (!domain.create_operation.eql(create_key)) return error.StaleCreateOperation;
        if (domain.lifecycle == .attached) return error.LifecycleDoesNotAllowStartupCancel;
        for (self.bindings.items) |binding| if (binding.owner.eql(owner)) {
            if (binding.startup_key == null or !binding.startup_key.?.eql(create_key)) return error.FileBindingNotPreparing;
            self.closeBinding(binding);
            return binding.service.?.closeReceipt();
        };
        return .released;
    }

    pub fn requestCloseAll(self: *FileBindingHost) void {
        for (self.bindings.items) |binding| self.closeBinding(binding);
    }

    pub fn deinit(self: *FileBindingHost) error{Busy}!void {
        if (self.bindings.items.len != 0) return error.Busy;
        for (self.responses.items) |*response| response.deinit();
        self.responses.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.finished_diagnostics.deinit(self.allocator);
    }

    fn validateHandles(self: *FileBindingHost, owner: identity.SessionHandle, handles: Bindings) !void {
        if (handles.directory.kind != .directory or handles.file_read.kind != .file_read) return error.ServiceKindMismatch;
        for ([_]sessions.ServiceHandle{ handles.directory, handles.file_read }) |handle| {
            if (handle.resource_owner != .session or !handle.resource_owner.session.eql(owner)) return error.OwnerMismatch;
            if (!self.sessions.bindingIsLive(handle)) return error.StaleBinding;
        }
    }
    fn validatePreparingHandles(self: *FileBindingHost, owner: identity.SessionHandle, key: operations.OperationKey, handles: Bindings) !void {
        const domain = self.sessions.queryState(owner) orelse return error.StaleSession;
        const recovering = self.sessions.sftpDirectoryRecoveryPreparing(handles.directory, key) and self.sessions.sftpDirectoryRecoveryPreparing(handles.file_read, key);
        if (!recovering) {
            if (!domain.create_operation.eql(key)) return error.StaleCreateOperation;
            if (domain.lifecycle != .creating) return error.SessionNotCreating;
        }
        if (handles.directory.kind != .directory or handles.file_read.kind != .file_read) return error.ServiceKindMismatch;
        for ([_]sessions.ServiceHandle{ handles.directory, handles.file_read }) |handle| {
            if (handle.resource_owner != .session or !handle.resource_owner.session.eql(owner)) return error.OwnerMismatch;
            if (!self.sessions.bindingIsPreparing(handle, key)) return error.StaleBinding;
        }
    }
    fn savedSpec(self: *FileBindingHost, owner: identity.SessionHandle) !sessions.SessionCreateSpec {
        // SessionHost owns this immutable request until shutdown. No lookup of
        // the editable asset registry, active tab, cwd or displayed host name.
        return self.sessions.engineSpec(owner) orelse error.StaleSession;
    }
    fn validateOperation(self: *FileBindingHost, owner: identity.SessionHandle, key: operations.OperationKey) !void {
        if (key.owner != .session or !key.owner.session.eql(owner)) return error.OwnerMismatch;
        for (self.sessions.journal.records.items) |record| if (record.key.eql(key)) {
            if (record.terminal) return error.OperationAlreadyTerminal;
            return;
        };
        return error.UnknownOperation;
    }
    fn resolve(self: *FileBindingHost, handle: sessions.ServiceHandle, action: readonly.Action) !*Binding {
        const kind: sessions.ServiceKind = if (action == .read_text) .file_read else .directory;
        if (handle.kind != kind) return error.ServiceKindMismatch;
        if (!self.sessions.bindingIsLive(handle)) return error.StaleBinding;
        for (self.bindings.items) |binding| {
            if (!(if (kind == .file_read) binding.handles.file_read else binding.handles.directory).eql(handle)) continue;
            if (binding.closing or binding.service == null) return error.FileServiceClosing;
            if (!self.current(binding)) return error.StaleBinding;
            return binding;
        }
        return error.FileBindingNotAttached;
    }
    fn current(self: *FileBindingHost, binding: *Binding) bool {
        if (binding.auxiliary) |start| return self.sessions.auxiliaryReadonlyOwns(binding.owner, start) and self.sessions.auxiliaryReadonlyIsCurrent(binding.owner, start.key);
        if (self.sessions.bindingIsLive(binding.handles.directory) and self.sessions.bindingIsLive(binding.handles.file_read)) return true;
        return if (binding.startup_key) |key| self.sessions.bindingIsPreparing(binding.handles.directory, key) and self.sessions.bindingIsPreparing(binding.handles.file_read, key) else false;
    }
    fn pendingCurrent(self: *FileBindingHost, pending: *const Pending) bool {
        if (self.sessions.bindingIsLive(pending.binding)) return true;
        return if (pending.startup_key) |key| self.sessions.bindingIsPreparing(pending.binding, key) else false;
    }
    fn findPreparing(self: *FileBindingHost, owner: identity.SessionHandle, key: operations.OperationKey) ?*Binding {
        for (self.bindings.items) |binding| if (binding.owner.eql(owner) and binding.startup_key != null and binding.startup_key.?.eql(key)) return binding;
        return null;
    }
    fn findEndpoint(self: *FileBindingHost, endpoint: readonly.EndpointRef) ?*Binding {
        for (self.bindings.items) |binding| if (binding.endpoint.eql(endpoint)) return binding;
        return null;
    }
    fn findPending(self: *FileBindingHost, key: operations.OperationKey) ?*Pending {
        for (self.pending.items) |*pending| if (pending.key.eql(key)) return pending;
        return null;
    }
    fn closeBinding(self: *FileBindingHost, binding: *Binding) void {
        binding.closing = true;
        if (binding.phase != .cleanup_unknown) binding.phase = .closing;
        // Abandoned intermediate pages must not fill the response queue and
        // prevent the bounded set of terminal/cleanup receipts from draining.
        var index: usize = 0;
        while (index < self.responses.items.len) {
            const value = self.responses.items[index].result.value;
            if (value.endpoint.eql(binding.endpoint) and !value.final) {
                var discarded = self.responses.orderedRemove(index);
                discarded.deinit();
            } else index += 1;
        }
        if (binding.service) |service| service.requestClose();
    }
    fn receive(self: *FileBindingHost, binding: *Binding, result: *readonly.OwnedResult) !bool {
        const value = &result.value;
        if (!value.endpoint.eql(binding.endpoint)) return error.WorkerEndpointMismatch;
        if (value.request_id == 0) {
            if (!value.key.eql(binding.open_key)) return error.WorkerOperationMismatch;
            switch (value.body) {
                .ready => if (!binding.closing and self.current(binding)) {
                    _ = try self.sessions.journal.publish(binding.open_key, .completed, "remote file binding ready", null);
                    if (binding.auxiliary) |start| if (!try self.sessions.auxiliaryReadonlyReady(binding.owner, start)) return error.StaleBinding;
                    binding.phase = .ready;
                } else {
                    _ = try self.sessions.journal.publish(binding.open_key, .cancelled, "file owner no longer live", null);
                    self.closeBinding(binding);
                },
                .failure => |failure| {
                    binding.failure = failure;
                    binding.phase = .failed;
                    _ = try self.sessions.journal.publish(binding.open_key, .failed, "", failureValue(failure, value.cleanup));
                },
                .cancelled => {
                    _ = try self.sessions.journal.publish(binding.open_key, .cancelled, "file binding cancelled", null);
                },
                .closed => if (value.cleanup == .unknown) {
                    _ = try self.sessions.journal.publish(binding.open_key, .cleanup_unknown, "file binding cleanup unknown", null);
                    binding.phase = .cleanup_unknown;
                },
                else => return error.WorkerOperationMismatch,
            }
            result.deinit();
            return true;
        }
        const pending = self.findPending(value.key) orelse return error.WorkerOperationMismatch;
        if (!pending.endpoint.eql(binding.endpoint) or value.request_id != value.key.operation_id) return error.WorkerOperationMismatch;
        const stale = !self.pendingCurrent(pending);
        if (stale and !value.final) {
            result.deinit();
            return true;
        }
        if (self.responses.items.len == response_limit) return false;
        if ((stale or pending.cancel_requested) and value.body != .created) value.body = .cancelled;
        if (value.final) {
            try self.publishTerminal(value);
            pending.terminal = true;
            pending.cleanup = value.cleanup;
        }
        self.responses.appendAssumeCapacity(.{ .binding = pending.binding, .stale = stale, .result = result.* });
        // A standalone directory transport failure is no longer writable/readable.
        // Keep its last UI projection, but actually release this original worker
        // before an explicit recovery may authenticate a replacement.
        const directory_recovery = if (self.sessions.manifestFor(binding.owner)) |manifest| manifest.integration.directory_recovery else false;
        if (value.final and value.body == .failure and directory_recovery and (value.body.failure == .connection or value.body.failure == .protocol)) self.closeBinding(binding);
        return true;
    }
    fn publishTerminal(self: *FileBindingHost, value: *const readonly.Result) !void {
        switch (value.body) {
            .cancelled => {
                _ = try self.sessions.journal.publish(value.key, .cancelled, "remote file request cancelled", null);
            },
            .failure => |failure| {
                if (value.cleanup == .released) {
                    _ = try self.sessions.journal.failReleased(value.key, failureValue(failure, .released));
                    return;
                }
                _ = try self.sessions.journal.publish(value.key, .failed, "", failureValue(failure, value.cleanup));
            },
            else => if (value.cleanup == .released) {
                _ = try self.sessions.journal.completeReleased(value.key, "remote file request completed");
                return;
            } else {
                _ = try self.sessions.journal.publish(value.key, .failed, "", failureValue(.close_failed, value.cleanup));
            },
        }
        _ = try self.sessions.journal.publish(value.key, switch (value.cleanup) {
            .released => .cleanup_released,
            .awaiting => .cleanup_progress,
            .unknown => .cleanup_unknown,
        }, "", null);
    }
    fn released(self: *FileBindingHost, binding: *Binding) !void {
        if (binding.startup_key) |key| _ = try self.sessions.sftpDirectoryRecoveryReleased(binding.handles.directory, key, .released);
        if (binding.auxiliary) |start| _ = try self.sessions.auxiliaryReadonlyReleased(binding.owner, start, .released);
        if (!self.sessions.journal.isTerminal(binding.open_key)) _ = try self.sessions.journal.publish(binding.open_key, .cancelled, "file binding closed", null);
        _ = try self.sessions.journal.publish(binding.open_key, .cleanup_released, "file binding released", null);
        for (self.pending.items) |*pending| if (pending.endpoint.eql(binding.endpoint) and pending.terminal and pending.cleanup != .released) {
            _ = try self.sessions.journal.publish(pending.key, .cleanup_released, "file binding released", null);
            pending.cleanup = .released;
        };
    }
    fn rejected(self: *FileBindingHost, key: operations.OperationKey, reason: []const u8) void {
        _ = self.sessions.journal.failReleased(key, .{ .domain = .host, .code = reason, .cleanup = .released, .safe_message = "远端文件请求未接收" }) catch return;
    }
};

fn failureValue(failure: readonly.Failure, cleanup: readonly.ReleaseReceipt) operations.Failure {
    return .{ .domain = .transport, .code = @tagName(failure), .cleanup = switch (cleanup) {
        .released => .released,
        .awaiting => .releasing,
        .unknown => .unknown,
    }, .safe_message = "远端文件服务请求失败" };
}

/// Ready-to-use direct Connector factory. Existing app trust/auth observers
/// remain explicit inputs; defaults never approve an unknown host key. Routed
/// sources are rejected before IO and can use a separate route-aware Factory.
pub const DirectFactory = struct {
    library: *const ssh.Library,
    known_hosts_path: []const u8,
    host_key_observer: ?ssh.HostKeyObserver = null,
    auth_interaction: ?ssh.AuthInteraction = null,
    timeout_ms: u32 = 15_000,

    pub fn interface(self: *DirectFactory) Factory {
        return .{ .context = self, .prepare = prepare, .discard = discard };
    }
    fn prepare(raw: *anyopaque, source: Source) !readonly.Connector {
        const self: *DirectFactory = @ptrCast(@alignCast(raw));
        if (!self.library.active) return error.LibraryNotInitialized;
        if (!std.fs.path.isAbsolute(self.known_hosts_path)) return error.InvalidTrustStorePath;
        const route = switch (source.spec) {
            .saved => |saved| saved.route_snapshot,
            .temporary_ssh => |temporary| temporary.route_snapshot,
            .local, .plugin => return error.UnsupportedProtocol,
        };
        if (route.len != 0) return error.ProxyJumpTransportUnavailable;
        const context = try std.heap.c_allocator.create(Native);
        errdefer std.heap.c_allocator.destroy(context);
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const path = try arena.allocator().dupe(u8, self.known_hosts_path);
        context.* = .{ .source = source, .policy = self.*, .arena = arena, .path = path, .ledger = try ssh.ResourceLedger.init(source.open_key, 1) };
        return .{ .key = source.open_key, .ctx = context, .connect_fn = Native.connect, .close_fn = Native.close, .deinit_fn = Native.destroy };
    }
    fn discard(_: *anyopaque, connector: readonly.Connector) void {
        Native.destroy(connector.ctx);
    }
    const Native = struct {
        source: Source,
        policy: DirectFactory,
        arena: std.heap.ArenaAllocator,
        path: []const u8,
        ledger: ssh.ResourceLedger,
        io: ?std.Io.Threaded = null,
        store: ?known.HostKeyStore = null,
        fn connect(raw: *anyopaque, cancelled: *const std.atomic.Value(bool)) !ssh.Session {
            const self: *Native = @ptrCast(@alignCast(raw));
            self.io = .init(std.heap.c_allocator, .{});
            self.store = try known.HostKeyStore.load(self.io.?.io(), std.Io.Dir.cwd(), std.heap.c_allocator, self.path);
            const allocator = self.arena.allocator();
            const remote: sessions.RemoteConfig = switch (self.source.spec) {
                .saved => |saved| saved.immutable_config,
                .temporary_ssh => |temporary| .{ .endpoint = temporary.structured_endpoint, .auth = temporary.auth_options, .strict_host_key_checking = temporary.strict_host_key_checking },
                .local, .plugin => return error.UnsupportedProtocol,
            };
            const auth: ssh.Auth = switch (remote.auth) {
                .agent => .agent,
                .password_prompt => .password_prompt,
                .keyboard_interactive => .keyboard_interactive,
                .password => |password| .{ .password = try allocator.dupeSentinel(u8, password, 0) },
                .private_key => |private| .{ .private_key = .{ .path = try allocator.dupeSentinel(u8, private.path, 0), .passphrase = if (private.passphrase) |pass| try allocator.dupeSentinel(u8, pass, 0) else null } },
            };
            return ssh.Session.connect(self.policy.library, .{
                .host = try allocator.dupeSentinel(u8, remote.endpoint.host, 0),
                .port = remote.endpoint.port,
                .user = try allocator.dupeSentinel(u8, remote.endpoint.user, 0),
                .auth = auth,
                .source_owner = switch (self.source.spec) {
                    .saved => |saved| .{ .id = saved.connection_id, .revision = saved.config_revision },
                    else => null,
                },
                .strict_host_key_checking = remote.strict_host_key_checking,
                .operation_key = self.source.open_key,
                .resource_ledger = &self.ledger,
                .host_key_store = &self.store.?,
                .host_key_observer = self.policy.host_key_observer,
                .auth_interaction = self.policy.auth_interaction,
                .cancel_token = cancelled,
                .connect_timeout_ms = self.policy.timeout_ms,
                .keepalive_sec = remote.keepalive_sec,
                .compression = remote.compression,
                .progress_observer = self.source.progress_observer,
                .attempt_id = self.source.open_key.attempt_id orelse 0,
                .open_shell = false,
            });
        }
        fn close(raw: *anyopaque, session: ?*ssh.Session) readonly.ReleaseReceipt {
            const self: *Native = @ptrCast(@alignCast(raw));
            if (session) |value| {
                const receipt = value.closeReceipt();
                if (receipt != .released) return receipt;
            }
            return self.ledger.drainRetained();
        }
        fn destroy(raw: *anyopaque) void {
            const self: *Native = @ptrCast(@alignCast(raw));
            if (self.store) |*store| store.deinit();
            if (self.io) |*io| io.deinit();
            self.arena.deinit();
            std.heap.c_allocator.destroy(self);
        }
    };
};
