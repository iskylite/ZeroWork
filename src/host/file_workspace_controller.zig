//! Control-thread directory/selection state for one frozen file workspace.
//! Native IO remains on local_fs/SFTP workers. No terminal, active tab lookup,
//! transfer execution or implicit connection replacement exists here.
const std = @import("std");
const identity = @import("identity.zig");
const operations = @import("operation.zig");
const sessions = @import("session_host.zig");
const files = @import("file_binding_host.zig");
pub const fs = @import("../local/fs_service.zig");
pub const View = @import("../ui/file_workspace_view.zig");
const remote = files.readonly;
pub const Side = View.Side;
pub const ReleaseReceipt = enum { released, awaiting, unknown };
const pending_limit = 16;
const history_limit = 64;

pub const Labels = struct { title: []const u8, subtitle: []const u8 = "", badge: []const u8 = "" };
pub const Local = struct {
    service: *fs.Service,
    journal: *operations.Journal,
    endpoint: fs.EndpointRef,
    initial_path: []const u8,
    /// Only an absolute directory already resolved by the real service may be
    /// supplied. Without it no projection is published until LIST succeeds.
    verified_path: ?[]const u8 = null,
    labels: Labels = .{ .title = "本地 · 此 Mac" },
    /// Explicit host authorization/capability, never inferred from listing.
    writable: bool = false,
};
pub const Remote = struct {
    host: *files.FileBindingHost,
    directory: sessions.ServiceHandle,
    endpoint: remote.EndpointRef,
    initial_path: []const u8 = ".",
    verified_path: ?[]const u8 = null,
    labels: Labels,
    writable: bool = false,
};
pub const Endpoint = union(enum) { local_fs: fs.EndpointRef, sftp: remote.EndpointRef };
pub const FrozenPane = struct {
    stamp: View.Stamp,
    endpoint: Endpoint,
    selection_revision: u64,
    directory: []const u8,
};
/// Borrowed through the callback's return. A host retaining this intent must
/// copy its strings/paths before returning; all identities are already values.
pub const FrozenTransfer = struct {
    owner: identity.SessionHandle,
    source: FrozenPane,
    destination: FrozenPane,
    paths: []const []const u8,
};
pub const HistoryEntry = struct { path: []const u8, succeeded: bool, failure: []const u8 = "" };
pub const Auxiliary = union(enum) {
    new_folder: View.Envelope,
    history: struct { envelope: View.Envelope, entries: []const HistoryEntry },
    context: View.Envelope,
    copy_paths: View.Envelope,
    recover: View.Envelope,
};
pub const Callbacks = struct {
    context: ?*anyopaque = null,
    transfer: ?*const fn (?*anyopaque, FrozenTransfer) anyerror!void = null,
    auxiliary: ?*const fn (?*anyopaque, Auxiliary) anyerror!void = null,
};
pub const Options = struct {
    owner: identity.SessionHandle,
    local: Local,
    remote: Remote,
    callbacks: Callbacks = .{},
    page_entries: u16 = 128,
    max_entries: u32 = 4096,
};
pub const PaneStatus = struct { state: View.State, failure: []const u8, request: ?operations.OperationKey, directory_revision: u64, selection_revision: u64 };
pub const MkdirPhase = enum { creating, refreshing, succeeded, failed, created_refresh_failed, stale };
pub const MkdirFailure = enum { already_exists, permission_denied, not_found, timeout, cancelled, unavailable, protocol, io };
pub const MkdirStatus = struct {
    key: operations.OperationKey,
    stamp: View.Stamp,
    name: []const u8,
    directory: []const u8,
    path: []const u8,
    phase: MkdirPhase = .creating,
    /// True only after the actual service's created receipt. False makes no
    /// assertion about effects of a disconnected/unknown remote request.
    created: bool = false,
    failure: ?MkdirFailure = null,
    refresh_key: ?operations.OperationKey = null,
};
const Mkdir = struct { arena: std.heap.ArenaAllocator, value: MkdirStatus };
/// Startup adapter handoff, after its final request really released/retired.
/// All slices borrow only through seedRemote; the controller owns its copy.
pub const InitialDirectory = struct {
    endpoint: remote.EndpointRef,
    key: operations.OperationKey,
    request_id: u64,
    directory_revision: u64,
    requested_path: []const u8,
    resolved_path: ?[]const u8,
    entries: []const remote.Entry,
    failure: ?remote.Failure = null,
    cleanup: remote.ReleaseReceipt = .released,
    retired: bool = true,
};
const Row = struct { entry: View.Entry, modified: ?u64 };
const Directory = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    rows: []Row,
    entries: []View.Entry,
    fn empty(allocator: std.mem.Allocator, directory_path: []const u8) !Directory {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = try arena.allocator().dupe(u8, directory_path);
        return .{ .arena = arena, .path = owned, .rows = &.{}, .entries = &.{} };
    }
    fn sort(self: *Directory, sort_: View.Sort) void {
        std.mem.sort(Row, self.rows, sort_, lessThan);
        for (self.rows, self.entries) |row, *entry| entry.* = row.entry;
    }
};
const Selection = struct {
    arena: std.heap.ArenaAllocator,
    value: View.Selection,
    fn init(allocator: std.mem.Allocator, value: View.Selection) !Selection {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const keys = try a.alloc([]const u8, value.keys.len);
        for (value.keys, keys) |key, *copy| copy.* = try a.dupe(u8, key);
        const anchor = if (value.anchor) |key| try a.dupe(u8, key) else null;
        const focused = if (value.focused_key) |key| try a.dupe(u8, key) else null;
        return .{ .arena = arena, .value = .{
            .keys = keys,
            .anchor = anchor,
            .focused_key = focused,
        } };
    }
};
const Mode = enum { navigate, refresh, back, forward };
const Pane = struct {
    directory: ?Directory = null,
    selection: ?Selection = null,
    state: View.State = .loading,
    failure: []const u8 = "",
    request_id: u64 = 0,
    directory_revision: u64 = 1,
    next_directory_revision: u64 = 1,
    selection_revision: u64 = 1,
    current: ?operations.OperationKey = null,
    sort: View.Sort = .{},
    history: std.ArrayList(HistoryEntry) = .empty,
    back: std.ArrayList([]const u8) = .empty,
    forward: std.ArrayList([]const u8) = .empty,
    mkdir: ?Mkdir = null,
};
const Work = struct {
    side: Side,
    key: operations.OperationKey,
    path: []u8,
    revision: u64,
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    rows: std.ArrayList(Row) = .empty,
    resolved: ?[]const u8 = null,
    next_page: u32 = 0,
    invalid: bool = false,
    terminal: bool = false,
    cleanup: ReleaseReceipt = .awaiting,
    mkdir: bool = false,
    fn deinit(self: *Work, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.arena.deinit();
    }
};

pub const Controller = struct {
    allocator: std.mem.Allocator,
    options_arena: std.heap.ArenaAllocator,
    options: Options,
    panes: [2]Pane = .{ .{}, .{} },
    pending: std.ArrayList(Work) = .empty,
    revision: u64 = 1,
    started: bool = false,
    closing: bool = false,
    remote_seeded: bool = false,

    /// Memory only. Both service lifetimes must exceed this controller and all
    /// accepted requests. Move into stable storage before viewCallbacks().
    pub fn init(allocator: std.mem.Allocator, options: Options) !Controller {
        if (@backingInt(options.owner.session_id) == 0 or options.owner.generation == 0) return error.InvalidOwner;
        if (!options.local.endpoint.eql(options.local.service.endpoint)) return error.StaleLocalBinding;
        // This is an app-owned FS endpoint, not a fabricated Local Session.
        if (options.local.endpoint.resource_owner != null) return error.LocalEndpointNotAppOwned;
        if (options.local.endpoint.binding_id == 0 or options.local.endpoint.binding_generation == 0) return error.InvalidBinding;
        if (options.remote.directory.kind != .directory or options.remote.directory.resource_owner != .session or !options.remote.directory.resource_owner.session.eql(options.owner)) return error.OwnerMismatch;
        if (options.remote.endpoint.resource_owner != .session or !options.remote.endpoint.resource_owner.session.eql(options.owner)) return error.OwnerMismatch;
        if (options.remote.endpoint.origin_session) |origin| if (!origin.eql(options.owner)) return error.OwnerMismatch;
        if (options.remote.directory.binding_id != options.remote.endpoint.binding_id or options.remote.directory.binding_generation != options.remote.endpoint.binding_generation) return error.StaleRemoteBinding;
        const state = options.remote.host.state(options.remote.directory) orelse return error.FileBindingNotAttached;
        if (!state.owner.eql(options.owner) or !state.endpoint.eql(options.remote.endpoint)) return error.StaleRemoteBinding;
        if (!options.remote.host.sessions.bindingIsLive(options.remote.directory)) return error.StaleRemoteBinding;
        if (options.page_entries == 0 or options.page_entries > fs.page_limit or options.max_entries == 0 or options.max_entries > fs.entry_limit) return error.InvalidEntryLimit;
        try path(options.local.initial_path);
        if (!absolute(options.local.initial_path) and !std.mem.eql(u8, options.local.initial_path, "~") and !std.mem.startsWith(u8, options.local.initial_path, "~/")) return error.AbsolutePathRequired;
        try path(options.remote.initial_path);
        if (!absolute(options.remote.initial_path) and !std.mem.eql(u8, options.remote.initial_path, ".")) return error.AbsolutePathRequired;
        var arena = std.heap.ArenaAllocator.init(allocator);
        var transferred = false;
        errdefer if (!transferred) arena.deinit();
        const a = arena.allocator();
        var copy = options;
        copy.local.initial_path = try a.dupe(u8, options.local.initial_path);
        copy.remote.initial_path = try a.dupe(u8, options.remote.initial_path);
        copy.local.labels = try cloneLabels(a, options.local.labels);
        copy.remote.labels = try cloneLabels(a, options.remote.labels);
        copy.local.verified_path = if (options.local.verified_path) |value| try a.dupe(u8, value) else null;
        copy.remote.verified_path = if (options.remote.verified_path) |value| try a.dupe(u8, value) else null;
        var self: Controller = .{ .allocator = allocator, .options_arena = arena, .options = copy };
        transferred = true;
        errdefer self.releaseMemory();
        for ([_]?[]const u8{ options.local.verified_path, options.remote.verified_path }, 0..) |verified, i| if (verified) |value| {
            try path(value);
            if (!absolute(value)) return error.AbsolutePathRequired;
            self.panes[i].directory = try Directory.empty(allocator, value);
        };
        // Own every option string too; no caller buffer survives by convention.
        try self.pending.ensureTotalCapacity(allocator, pending_limit);
        return self;
    }

    /// Reuses the real startup LIST without re-opening a directory. A failed
    /// startup read preserves its typed failure; it never becomes empty/ready.
    pub fn seedRemote(self: *Controller, source: InitialDirectory) !void {
        if (self.started or self.closing or self.remote_seeded) return error.FileWorkspaceStarted;
        if (!source.endpoint.eql(self.options.remote.endpoint)) return error.ResultEndpointMismatch;
        if (source.key.owner != .session or !source.key.owner.session.eql(self.options.owner)) return error.OwnerMismatch;
        if (source.request_id == 0 or source.request_id != source.key.operation_id or source.directory_revision == 0) return error.ResultRequestMismatch;
        if (!source.retired or source.cleanup != .released) return error.DirectoryStartupNotReleased;
        for (self.options.remote.host.pending.items) |pending| if (pending.key.eql(source.key)) return error.DirectoryStartupNotReleased;
        try path(source.requested_path);
        if (source.resolved_path) |resolved| {
            try path(resolved);
            if (!absolute(resolved)) return error.AbsolutePathRequired;
        }
        if (source.entries.len > self.options.max_entries) return error.InvalidEntryLimit;
        const pane = &self.panes[1];
        if (source.failure) |failure| {
            var next: ?Directory = if (source.resolved_path) |resolved| try Directory.empty(self.allocator, resolved) else null;
            errdefer if (next) |*value| value.arena.deinit();
            try self.bump();
            if (pane.directory) |*old| old.arena.deinit();
            pane.directory = next;
            pane.state = .failed;
            pane.failure = failureMessage(failure);
        } else {
            const resolved = source.resolved_path orelse return error.DirectoryPathUnresolved;
            var work: Work = .{ .side = .remote, .key = source.key, .path = try self.allocator.dupe(u8, source.requested_path), .revision = source.directory_revision, .mode = .refresh, .arena = std.heap.ArenaAllocator.init(self.allocator) };
            defer work.deinit(self.allocator);
            const a = work.arena.allocator();
            work.resolved = try a.dupe(u8, resolved);
            for (source.entries) |entry| {
                if (!validEntry(resolved, entry) or rowIndex(work.rows.items, entry.absolute_path) != null) return error.InvalidDirectoryEntry;
                try work.rows.append(a, try convertEntry(a, entry));
            }
            try self.commit(&work);
        }
        pane.current = source.key;
        pane.request_id = source.request_id;
        pane.directory_revision = source.directory_revision;
        pane.next_directory_revision = source.directory_revision;
        self.remote_seeded = true;
    }

    pub fn start(self: *Controller) !void {
        if (self.closing) return error.FileWorkspaceClosing;
        if (self.started) return error.FileWorkspaceStarted;
        self.started = true;
        try self.submit(.local, self.options.local.initial_path, .navigate);
        if (!self.remote_seeded) try self.submit(.remote, self.options.remote.initial_path, .navigate);
    }

    /// No synthetic absolute path is exposed for an unresolved server '.'.
    /// The returned slices borrow until the next controller mutation.
    pub fn projection(self: *const Controller) ?View.Projection {
        if (!self.started) return null;
        if (self.panes[0].directory == null or self.panes[1].directory == null) return null;
        if (self.panes[0].request_id == 0 or self.panes[1].request_id == 0) return null;
        return .{ .revision = self.revision, .owner = self.options.owner, .panes = .{ self.projectPane(.local), self.projectPane(.remote) } };
    }
    pub fn paneStatus(self: *const Controller, side: Side) PaneStatus {
        const pane = &self.panes[index(side)];
        return .{ .state = pane.state, .failure = pane.failure, .request = pane.current, .directory_revision = pane.directory_revision, .selection_revision = pane.selection_revision };
    }
    /// Borrowed until the next mutation. The UI can retain the failed input
    /// independently of the directory listing; creation and refresh differ.
    pub fn mkdirStatus(self: *const Controller, side: Side) ?MkdirStatus {
        return if (self.panes[index(side)].mkdir) |value| value.value else null;
    }

    /// Submit one literal child name against the original card stamp. No UI
    /// focus lookup, transfer intent or navigation into the created directory.
    pub fn mkdir(self: *Controller, envelope: View.Envelope, name: []const u8) !operations.OperationKey {
        try self.validateEnvelope(envelope);
        try @import("directory_name.zig").validate(name);
        const side = envelope.side;
        const pane = &self.panes[index(side)];
        if (!fresh(pane.state) or !self.endpointLive(side)) return error.StaleDirectory;
        if (!(if (side == .local) self.options.local.writable else self.options.remote.writable)) return error.DirectoryNotWritable;
        if (self.pending.items.len == pending_limit) return error.DirectoryRequestLimit;
        if (pane.mkdir) |current| if (current.value.phase == .creating or current.value.phase == .refreshing) return error.MkdirPending;
        const revision = try identity.advance(self.revision);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const parent_path = try a.dupe(u8, pane.directory.?.path);
        const owned_name = try a.dupe(u8, name);
        const target = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ parent_path, if (std.mem.endsWith(u8, parent_path, "/")) @as([]const u8, "") else "/", owned_name });
        try path(target);
        const work_path = try self.allocator.dupe(u8, parent_path);
        errdefer self.allocator.free(work_path);
        const key = switch (side) {
            .local => blk: {
                const key = try self.options.local.journal.begin(.app, null);
                self.options.local.service.submit(key, .{ .endpoint = self.options.local.endpoint, .request_id = key.operation_id, .directory_revision = pane.directory_revision, .path = work_path, .action = .{ .mkdir = .{ .name = owned_name } } }) catch |err| {
                    _ = self.options.local.journal.failReleased(key, .{ .domain = .host, .code = @errorName(err), .cleanup = .released, .safe_message = "新建目录请求未接收" }) catch {};
                    self.options.local.journal.retire(key, .resources_released) catch {};
                    return err;
                };
                break :blk key;
            },
            .remote => try self.options.remote.host.begin(self.options.remote.directory, .{ .path = work_path, .action = .{ .mkdir = .{ .name = owned_name } }, .directory_revision = pane.directory_revision }),
        };
        if (pane.mkdir) |*previous| previous.arena.deinit();
        pane.mkdir = .{ .arena = arena, .value = .{ .key = key, .stamp = envelope.stamp, .name = owned_name, .directory = parent_path, .path = target } };
        self.pending.appendAssumeCapacity(.{ .side = side, .key = key, .path = work_path, .revision = pane.directory_revision, .mode = .refresh, .mkdir = true, .arena = std.heap.ArenaAllocator.init(self.allocator) });
        self.revision = revision;
        return key;
    }
    /// Initial error containers have no View stamp until a real absolute path
    /// exists. Retry only that side's frozen initial request on the same binding.
    pub fn retryInitial(self: *Controller, side: Side) !void {
        if (!self.started) return error.FileWorkspaceNotStarted;
        if (self.panes[index(side)].directory != null) return error.UseFrozenFileEnvelope;
        try self.submit(side, if (side == .local) self.options.local.initial_path else self.options.remote.initial_path, .refresh);
    }
    pub fn viewCallbacks(self: *Controller) View.Callbacks {
        return .{ .context = self, .action = onAction, .external_upload = onExternalUpload, .current_stamp = currentViewStamp, .current_projection = currentViewProjection };
    }
    fn currentViewProjection(raw: *anyopaque) ?View.Projection {
        const self: *Controller = @ptrCast(@alignCast(raw));
        return self.projection();
    }
    fn currentViewStamp(raw: *anyopaque, side: Side) View.Stamp {
        const self: *Controller = @ptrCast(@alignCast(raw));
        var stamp = self.projectPane(side).stamp;
        stamp.directory_revision = self.panes[index(side)].next_directory_revision;
        return stamp;
    }
    fn onExternalUpload(raw: *anyopaque, request: View.ExternalUpload) !void {
        const self: *Controller = @ptrCast(@alignCast(raw));
        try self.externalUpload(request);
    }
    /// Finder supplies explicit local source paths; it does not select or
    /// navigate the local pane. Freeze both endpoints and the original target.
    pub fn externalUpload(self: *Controller, request: View.ExternalUpload) !void {
        if (self.closing) return error.FileWorkspaceClosing;
        const callback = self.options.callbacks.transfer orelse return error.UnsupportedFileAction;
        const source = self.projectPane(.local);
        const destination = self.projectPane(.remote);
        if (!fresh(source.state) or !fresh(destination.state) or !destination.writable or !self.endpointLive(.local) or !self.endpointLive(.remote)) return error.FileTransferUnavailable;
        if (!std.meta.eql(request.destination, destination.stamp)) return error.StaleTransferDestination;
        if (request.target_entry) |target| {
            const at = entryIndex(destination.entries, target) orelse return error.StaleTransferDestination;
            if (destination.entries[at].kind != .directory or !std.mem.eql(u8, request.directory, target)) return error.InvalidTransferDirectory;
        } else if (!std.mem.eql(u8, request.directory, destination.resolved_path)) return error.StaleTransferDestination;
        if (request.paths.len == 0 or request.paths.len > 1024) return error.InvalidFileSelection;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var paths: std.ArrayList([]const u8) = .empty;
        for (request.paths) |value| {
            try path(value);
            if (!absolute(value)) return error.AbsolutePathRequired;
            var duplicate = false;
            for (paths.items) |previous| if (std.mem.eql(u8, previous, value)) {
                duplicate = true;
                break;
            };
            if (!duplicate) try paths.append(a, try a.dupe(u8, value));
        }
        try callback(self.options.callbacks.context, .{
            .owner = self.options.owner,
            .source = .{ .stamp = source.stamp, .endpoint = self.endpoint(.local), .selection_revision = source.selection_revision, .directory = try a.dupe(u8, source.resolved_path) },
            .destination = .{ .stamp = destination.stamp, .endpoint = self.endpoint(.remote), .selection_revision = destination.selection_revision, .directory = try a.dupe(u8, request.directory) },
            .paths = paths.items,
        });
    }
    fn onAction(raw: *anyopaque, envelope: View.Envelope) !void {
        const self: *Controller = @ptrCast(@alignCast(raw));
        try self.handle(envelope);
    }

    pub fn handle(self: *Controller, envelope: View.Envelope) !void {
        try self.validateEnvelope(envelope);
        const pane = &self.panes[index(envelope.side)];
        const directory = &pane.directory.?;
        switch (envelope.action) {
            .navigate => |navigation| {
                if (!std.mem.eql(u8, navigation.base_directory, directory.path)) return error.StaleDirectory;
                const joined = try navigationPath(self.allocator, envelope.side, directory.path, navigation.requested_path);
                defer self.allocator.free(joined);
                try self.submit(envelope.side, joined, .navigate);
            },
            .refresh => try self.submit(envelope.side, directory.path, .refresh),
            .back => {
                if (pane.back.items.len == 0) return error.NoDirectoryHistory;
                try self.submit(envelope.side, pane.back.items[pane.back.items.len - 1], .back);
            },
            .parent => try self.submit(envelope.side, parent(directory.path), .navigate),
            .sort => |sort_| {
                try self.bump();
                pane.sort = sort_;
                directory.sort(sort_);
            },
            .selection => |selection| try self.select(envelope.side, selection),
            .context => |selection| {
                const callback = self.options.callbacks.auxiliary orelse return error.UnsupportedFileAction;
                try self.validateSelection(envelope.side, selection);
                try self.select(envelope.side, selection);
                var acknowledged = envelope;
                acknowledged.projection_revision = self.revision;
                acknowledged.selection_revision = pane.selection_revision;
                acknowledged.action = .{ .context = pane.selection.?.value };
                try callback(self.options.callbacks.context, .{ .context = acknowledged });
            },
            .copy_paths => |selection| {
                try self.validateSelection(envelope.side, selection);
                const callback = self.options.callbacks.auxiliary orelse return error.UnsupportedFileAction;
                try callback(self.options.callbacks.context, .{ .copy_paths = envelope });
            },
            .history => {
                const callback = self.options.callbacks.auxiliary orelse return error.UnsupportedFileAction;
                try callback(self.options.callbacks.context, .{ .history = .{ .envelope = envelope, .entries = pane.history.items } });
            },
            .transfer => |value| try self.transfer(envelope, value),
            .recover => {
                // Re-reading a live endpoint is safe; reconnecting requires the
                // host's explicit original-owner recovery, never a replacement.
                if (self.endpointLive(envelope.side)) return self.submit(envelope.side, directory.path, .refresh);
                const callback = self.options.callbacks.auxiliary orelse return error.UnsupportedFileAction;
                try callback(self.options.callbacks.context, .{ .recover = envelope });
            },
            .new_folder => {
                if (!fresh(pane.state) or !self.endpointLive(envelope.side)) return error.StaleDirectory;
                if (!(if (envelope.side == .local) self.options.local.writable else self.options.remote.writable)) return error.DirectoryNotWritable;
                const callback = self.options.callbacks.auxiliary orelse return error.UnsupportedFileAction;
                try callback(self.options.callbacks.context, .{ .new_folder = envelope });
            },
        }
    }

    /// A fresh authenticated directory connection replaces only this original
    /// owner's revoked read endpoint. Last successful path/list/selection remain
    /// visible until the real refresh succeeds; no task target is rewritten.
    pub fn rebindRemote(self: *Controller, previous: sessions.ServiceHandle, next: sessions.SftpDirectoryPair, endpoint_: remote.EndpointRef) !void {
        if (self.closing) return error.FileWorkspaceClosing;
        if (!self.options.remote.directory.eql(previous)) return error.StaleBinding;
        for (self.pending.items) |work| if (work.side == .remote) return error.DirectoryRecoveryStillDraining;
        if (!self.options.remote.host.sessions.bindingIsLive(next.directory) or !self.options.remote.host.sessions.bindingIsLive(next.file_read)) return error.StaleBinding;
        if (next.directory.resource_owner != .session or !next.directory.resource_owner.session.eql(self.options.owner)) return error.OwnerMismatch;
        const state = self.options.remote.host.state(next.directory) orelse return error.FileBindingNotAttached;
        if (state.phase != .ready or !state.owner.eql(self.options.owner) or !state.endpoint.eql(endpoint_)) return error.FileBindingNotReady;
        self.options.remote.directory = next.directory;
        self.options.remote.endpoint = endpoint_;
        const pane = &self.panes[1];
        pane.state = .stale;
        pane.failure = "已重新认证，正在重读原目录";
        try self.bump();
        const directory = pane.directory orelse return error.FileProjectionUnavailable;
        try self.submit(.remote, directory.path, .refresh);
    }
    pub fn directoryRecoveryMessage(self: *Controller, message: []const u8) !void {
        if (self.closing) return;
        const pane = &self.panes[1];
        if (pane.state == .stale and std.mem.eql(u8, pane.failure, message)) return;
        pane.state = .stale;
        pane.failure = message;
        try self.bump();
    }

    /// Remove only this card's matching history record, never directory data.
    pub fn removeHistory(self: *Controller, envelope: View.Envelope, value: []const u8) !void {
        try self.validateEnvelope(envelope);
        const pane = &self.panes[index(envelope.side)];
        var at = pane.history.items.len;
        while (at > 0) {
            at -= 1;
            if (!std.mem.eql(u8, pane.history.items[at].path, value)) continue;
            try self.bump();
            const removed = pane.history.orderedRemove(at);
            self.allocator.free(removed.path);
            self.allocator.free(removed.failure);
            return;
        }
        return error.StaleHistoryEntry;
    }

    /// Optional host history/forward menu uses the same frozen envelope gate.
    pub fn forward(self: *Controller, envelope: View.Envelope) !void {
        try self.validateEnvelope(envelope);
        const pane = &self.panes[index(envelope.side)];
        if (pane.forward.items.len == 0) return error.NoDirectoryHistory;
        try self.submit(envelope.side, pane.forward.items[pane.forward.items.len - 1], .forward);
    }

    /// Dispatcher entry: borrows a result and never deinitializes it. False
    /// means another consumer owns that key, so continue routing it there.
    pub fn acceptLocal(self: *Controller, result: fs.Result) !bool {
        const at = self.find(result.key, .local) orelse return false;
        if (!result.endpoint.eql(self.options.local.endpoint)) return error.ResultEndpointMismatch;
        try self.validateResult(at, result.request_id, result.directory_revision, result.requested_path);
        try self.receive(at, result.resolved_path, result.body, result.final, receipt(result.cleanup), false);
        if (result.final) {
            const work = &self.pending.items[at];
            switch (result.body) {
                .failure => |failure| {
                    const failure_value: operations.Failure = .{ .domain = .host, .code = @tagName(failure), .cleanup = if (result.cleanup == .released) .released else .unknown, .safe_message = "本地目录读取失败" };
                    if (result.cleanup == .released) {
                        _ = try self.options.local.journal.failReleased(work.key, failure_value);
                    } else {
                        _ = try self.options.local.journal.publish(work.key, .failed, "", failure_value);
                    }
                },
                .cancelled => {
                    _ = try self.options.local.journal.publish(work.key, .cancelled, "local directory request cancelled", null);
                    if (result.cleanup == .released) _ = try self.options.local.journal.publish(work.key, .cleanup_released, "", null);
                },
                else => if (result.cleanup == .released) {
                    _ = try self.options.local.journal.completeReleased(work.key, "local directory request completed");
                },
            }
        }
        try self.retireReady();
        return true;
    }

    /// AppHost still owns FileBindingHost.safeTick. Only this controller's
    /// remote keys are consumed here; unrelated tools retain their responses.
    pub fn pump(self: *Controller) !bool {
        var changed = false;
        for (0..16) |_| {
            var delivered = false;
            var at: usize = 0;
            while (at < self.pending.items.len) : (at += 1) {
                const work = self.pending.items[at];
                if (work.side != .remote or work.terminal) continue;
                var response = self.options.remote.host.take(work.key) orelse continue;
                defer response.deinit();
                if (!response.binding.eql(self.options.remote.directory) or !response.result.value.endpoint.eql(self.options.remote.endpoint)) return error.ResultEndpointMismatch;
                const value = response.result.value;
                try self.validateResult(at, value.request_id, value.directory_revision, value.requested_path);
                try self.receive(at, value.resolved_path, value.body, value.final, receipt(value.cleanup), response.stale);
                delivered = true;
                changed = true;
                break;
            }
            if (!delivered) break;
        }
        try self.retireReady();
        if (!self.closing and !self.endpointLive(.remote)) {
            const pane = &self.panes[1];
            if (pane.state != .stale) {
                try self.bump();
                pane.state = .stale;
                pane.failure = "连接已失效，请重新连接";
                changed = true;
            }
        }
        return changed;
    }

    pub fn requestClose(self: *Controller) void {
        if (self.closing) return;
        self.closing = true;
        self.bump() catch {};
        for (&self.panes) |*pane| {
            pane.state = .stale;
            pane.failure = "文件工作区已关闭";
            if (pane.mkdir) |*value| if (value.value.phase == .creating or value.value.phase == .refreshing) {
                value.value.phase = .stale;
            };
        }
        for (self.pending.items) |work| if (!work.terminal) self.cancel(work);
    }
    pub fn closeReceipt(self: *const Controller) ReleaseReceipt {
        if (!self.closing) return .awaiting;
        var result: ReleaseReceipt = .released;
        for (self.pending.items) |work| {
            if (work.cleanup == .unknown) return .unknown;
            if (!work.terminal or work.cleanup != .released) result = .awaiting;
        }
        return result;
    }
    pub fn deinit(self: *Controller) error{Busy}!void {
        if (self.closeReceipt() != .released or self.pending.items.len != 0) return error.Busy;
        self.releaseMemory();
        self.* = undefined;
    }

    fn submit(self: *Controller, side: Side, requested: []const u8, mode: Mode) !void {
        if (self.closing) return error.FileWorkspaceClosing;
        if (!self.endpointLive(side)) return error.StaleBinding;
        if (self.pending.items.len == pending_limit) return error.DirectoryRequestLimit;
        try path(requested);
        const pane = &self.panes[index(side)];
        const next_revision = try identity.advance(pane.next_directory_revision);
        const next_projection = try identity.advance(self.revision);
        const owned = try self.allocator.dupe(u8, requested);
        errdefer self.allocator.free(owned);
        const key = switch (side) {
            .local => blk: {
                const key = try self.options.local.journal.begin(.app, null);
                self.options.local.service.submit(key, .{ .endpoint = self.options.local.endpoint, .request_id = key.operation_id, .directory_revision = next_revision, .path = owned, .action = .{ .list = .{ .page_entries = self.options.page_entries, .max_entries = self.options.max_entries } } }) catch |err| {
                    _ = self.options.local.journal.failReleased(key, .{ .domain = .host, .code = @errorName(err), .cleanup = .released, .safe_message = "本地目录请求未接收" }) catch {};
                    self.options.local.journal.retire(key, .resources_released) catch {};
                    return err;
                };
                break :blk key;
            },
            .remote => try self.options.remote.host.begin(self.options.remote.directory, .{ .path = owned, .action = .{ .list = .{ .page_entries = self.options.page_entries, .max_entries = self.options.max_entries } }, .directory_revision = next_revision }),
        };
        if (pane.current) |previous| if (self.find(previous, side)) |at| self.cancel(self.pending.items[at]);
        self.pending.appendAssumeCapacity(.{ .side = side, .key = key, .path = owned, .revision = next_revision, .mode = mode, .arena = std.heap.ArenaAllocator.init(self.allocator) });
        pane.current = key;
        pane.request_id = key.operation_id;
        pane.next_directory_revision = next_revision;
        pane.state = .loading;
        pane.failure = "";
        if (pane.mkdir) |*value| if (value.value.phase == .creating or value.value.phase == .refreshing) {
            // A later navigation may not be overwritten by this old mutation.
            value.value.phase = .stale;
        };
        self.revision = next_projection;
    }
    fn validateEnvelope(self: *const Controller, envelope: View.Envelope) !void {
        if (self.closing) return error.FileWorkspaceClosing;
        if (!envelope.stamp.owner.eql(self.options.owner)) return error.OwnerMismatch;
        const current = self.projection() orelse return error.FileProjectionUnavailable;
        const pane = current.panes[index(envelope.side)];
        if (envelope.projection_revision != current.revision or !std.meta.eql(envelope.stamp, pane.stamp) or envelope.selection_revision != pane.selection_revision) return error.StaleFileAction;
    }
    fn validateResult(self: *Controller, at: usize, request_id: u64, revision: u64, requested: []const u8) !void {
        const work = &self.pending.items[at];
        if (work.terminal) return error.DuplicateDirectoryTerminal;
        if (request_id != work.key.operation_id or revision != work.revision or !std.mem.eql(u8, requested, work.path)) return error.ResultRequestMismatch;
    }
    fn receive(self: *Controller, at: usize, resolved: ?[]const u8, body: anytype, final: bool, cleanup: ReleaseReceipt, stale: bool) !void {
        if (self.pending.items[at].mkdir) return self.receiveMkdir(at, body, final, cleanup, stale);
        const work = &self.pending.items[at];
        const pane = &self.panes[index(work.side)];
        const current = !self.closing and pane.current != null and pane.current.?.eql(work.key);
        if (stale or cleanup == .unknown) work.invalid = true;
        if (current and !work.invalid) switch (body) {
            .page => |page_| {
                if (page_.index != work.next_page or work.rows.items.len + page_.entries.len > self.options.max_entries) {
                    self.failWork(work, "目录响应不完整，请重试");
                } else if (resolved) |value| {
                    if (!absolute(value) or value.len > fs.path_limit or (work.resolved != null and !std.mem.eql(u8, work.resolved.?, value))) {
                        self.failWork(work, "目录响应已变化，请重试");
                    } else {
                        const a = work.arena.allocator();
                        if (work.resolved == null) work.resolved = try a.dupe(u8, value);
                        for (page_.entries) |entry| {
                            if (!validEntry(value, entry) or rowIndex(work.rows.items, entry.absolute_path) != null) {
                                self.failWork(work, "目录响应不完整，请重试");
                                break;
                            }
                            const converted = try convertEntry(a, entry);
                            try work.rows.append(a, converted);
                        }
                        work.next_page += 1;
                    }
                } else self.failWork(work, "目录路径未解析，请重试");
            },
            .failure => |failure| self.failWork(work, failureMessage(failure)),
            .cancelled => self.failWork(work, "目录读取已取消"),
            else => self.failWork(work, "目录响应无效，请重试"),
        };
        if (!final) return;
        work.terminal = true;
        work.cleanup = cleanup;
        if (!current) return;
        if (stale or cleanup != .released) {
            try self.bump();
            pane.state = .stale;
            pane.failure = if (stale) "目录内容已过期，请重新读取" else "目录资源释放待确认";
        } else if (!work.invalid and work.resolved != null) {
            try self.commit(work);
        } else {
            try self.bump();
            pane.state = .failed;
            if (pane.failure.len == 0) pane.failure = "目录读取失败，请重试";
            try self.addHistory(pane, work.path, false, pane.failure);
        }
        try self.finishMkdirRefresh(work);
    }

    fn receiveMkdir(self: *Controller, at: usize, body: anytype, final: bool, cleanup: ReleaseReceipt, stale: bool) !void {
        const work = &self.pending.items[at];
        if (!final) return error.InvalidMkdirResult;
        work.terminal = true;
        work.cleanup = cleanup;
        const side = work.side;
        const pane = &self.panes[index(side)];
        const record = if (pane.mkdir) |*value| value else return;
        const status = &record.value;
        if (!status.key.eql(work.key)) return;
        if (body == .created) {
            if (!std.mem.eql(u8, body.created, status.path)) {
                status.phase = .stale;
                status.failure = .protocol;
                try self.bump();
                return;
            }
            status.created = true;
        }
        if (body == .failure) status.failure = mkdirCode(@tagName(body.failure));
        if (body == .cancelled) status.failure = .cancelled;
        const current = !self.closing and !stale and self.endpointLive(side) and
            pane.request_id == status.stamp.request_id and pane.directory_revision == status.stamp.directory_revision and
            pane.directory != null and std.mem.eql(u8, pane.directory.?.path, status.directory);
        try self.bump();
        if (!current or cleanup != .released) {
            status.phase = .stale;
            return;
        }
        switch (body) {
            .created => {
                self.submit(side, status.directory, .refresh) catch |err| {
                    status.phase = .created_refresh_failed;
                    status.failure = mkdirError(err);
                    return;
                };
                status.refresh_key = pane.current;
                status.phase = .refreshing;
                status.failure = null;
            },
            .failure => |failure| {
                status.phase = .failed;
                status.failure = mkdirCode(@tagName(failure));
            },
            .cancelled => {
                status.phase = .failed;
                status.failure = .cancelled;
            },
            else => {
                status.phase = .stale;
                status.failure = .protocol;
            },
        }
    }

    fn finishMkdirRefresh(self: *Controller, work: *Work) !void {
        const pane = &self.panes[index(work.side)];
        const value = if (pane.mkdir) |*record| &record.value else return;
        if (value.refresh_key == null or !value.refresh_key.?.eql(work.key) or value.phase != .refreshing) return;
        if (!fresh(pane.state)) {
            value.phase = .created_refresh_failed;
            value.failure = if (pane.state == .stale) .unavailable else .io;
            return;
        }
        const entries = pane.directory.?.entries;
        const at = entryIndex(entries, value.path) orelse {
            value.phase = .created_refresh_failed;
            value.failure = .not_found;
            return;
        };
        if (entries[at].kind != .directory) {
            value.phase = .created_refresh_failed;
            value.failure = .protocol;
            return;
        }
        try self.select(work.side, .{ .keys = &.{value.path}, .anchor = value.path, .focused_key = value.path });
        value.phase = .succeeded;
        value.failure = null;
    }
    fn failWork(self: *Controller, work: *Work, message: []const u8) void {
        work.invalid = true;
        const pane = &self.panes[index(work.side)];
        pane.failure = message;
        if (!work.terminal) self.cancel(work.*);
    }
    fn commit(self: *Controller, work: *Work) !void {
        const pane = &self.panes[index(work.side)];
        const a = work.arena.allocator();
        const entries = try a.alloc(View.Entry, work.rows.items.len);
        var next: Directory = .{ .arena = work.arena, .path = work.resolved.?, .rows = work.rows.items, .entries = entries };
        next.sort(pane.sort);
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(self.allocator);
        const previous: View.Selection = if (pane.selection) |selection| selection.value else .{ .keys = &.{}, .anchor = null, .focused_key = null };
        // Refresh keeps keys that still exist, never the old row numbers.
        const same_directory = if (pane.directory) |directory| std.mem.eql(u8, directory.path, next.path) else false;
        if (same_directory) for (previous.keys) |key| if (entryIndex(next.entries, key) != null) try keys.append(self.allocator, key);
        var selection = try Selection.init(self.allocator, .{
            .keys = keys.items,
            .anchor = if (same_directory and optionalExists(next.entries, previous.anchor)) previous.anchor else null,
            .focused_key = if (same_directory and optionalExists(next.entries, previous.focused_key)) previous.focused_key else null,
        });
        errdefer selection.arena.deinit();
        const selection_revision = try identity.advance(pane.selection_revision);
        const revision = try identity.advance(self.revision);
        try self.updateHistory(pane, next.path, work.mode);
        try self.addHistory(pane, next.path, true, "");
        if (pane.directory) |*old| old.arena.deinit();
        if (pane.selection) |*old| old.arena.deinit();
        pane.directory = next;
        work.arena = std.heap.ArenaAllocator.init(self.allocator);
        work.rows = .empty;
        work.resolved = null;
        pane.selection = selection;
        pane.selection_revision = selection_revision;
        pane.directory_revision = work.revision;
        pane.state = if (next.entries.len == 0) .empty else .ready;
        pane.failure = "";
        self.revision = revision;
    }
    fn select(self: *Controller, side: Side, value: View.Selection) !void {
        try self.validateSelection(side, value);
        const pane = &self.panes[index(side)];
        var owned = try Selection.init(self.allocator, value);
        errdefer owned.arena.deinit();
        const revision = try identity.advance(pane.selection_revision);
        try self.bump();
        if (pane.selection) |*old| old.arena.deinit();
        pane.selection = owned;
        pane.selection_revision = revision;
    }
    fn validateSelection(self: *const Controller, side: Side, value: View.Selection) !void {
        const directory = self.panes[index(side)].directory orelse return error.FileProjectionUnavailable;
        if (value.keys.len > directory.entries.len) return error.InvalidFileSelection;
        for (value.keys, 0..) |key, i| {
            const at = entryIndex(directory.entries, key) orelse return error.InvalidFileSelection;
            if (isParent(directory.entries[at]) or contains(value.keys[0..i], key)) return error.InvalidFileSelection;
        }
        if (value.anchor) |key| {
            const at = entryIndex(directory.entries, key) orelse return error.InvalidFileSelection;
            if (isParent(directory.entries[at])) return error.InvalidFileSelection;
        }
        if (value.focused_key) |key| if (entryIndex(directory.entries, key) == null) return error.InvalidFileSelection;
    }
    fn transfer(self: *Controller, envelope: View.Envelope, request: View.Transfer) !void {
        const callback = self.options.callbacks.transfer orelse return error.UnsupportedFileAction;
        const source = self.projectPane(envelope.side);
        const other: Side = if (envelope.side == .local) .remote else .local;
        const destination = self.projectPane(other);
        if (!fresh(source.state) or !fresh(destination.state) or !source.can_transfer or !destination.writable or !self.endpointLive(envelope.side) or !self.endpointLive(other)) return error.FileTransferUnavailable;
        if (!std.meta.eql(request.destination, destination.stamp)) return error.StaleTransferDestination;
        if (request.target_entry) |target| {
            const at = entryIndex(destination.entries, target) orelse return error.StaleTransferDestination;
            if (destination.entries[at].kind != .directory or !std.mem.eql(u8, request.directory, target)) return error.InvalidTransferDirectory;
        } else if (!std.mem.eql(u8, request.directory, destination.resolved_path)) return error.StaleTransferDestination;
        try self.validateSelection(envelope.side, request.selection);
        if (request.selection.keys.len == 0 or !equalKeys(request.selection.keys, source.selected_keys) or !equalOptional(request.selection.anchor, source.anchor) or !equalOptional(request.selection.focused_key, source.focused_key)) return error.StaleFileSelection;
        // Own callback text as one immutable snapshot. Reentrant navigation
        // cannot retarget it or free paths while a host publishes the intent.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const paths = try a.alloc([]const u8, request.selection.keys.len);
        for (request.selection.keys, paths) |key, *copy| copy.* = try a.dupe(u8, key);
        try callback(self.options.callbacks.context, .{
            .owner = self.options.owner,
            .source = .{ .stamp = source.stamp, .endpoint = self.endpoint(envelope.side), .selection_revision = source.selection_revision, .directory = try a.dupe(u8, source.resolved_path) },
            .destination = .{ .stamp = destination.stamp, .endpoint = self.endpoint(other), .selection_revision = destination.selection_revision, .directory = try a.dupe(u8, request.directory) },
            .paths = paths,
        });
    }
    fn projectPane(self: *const Controller, side: Side) View.PaneProjection {
        const pane = &self.panes[index(side)];
        const local = side == .local;
        const labels = if (local) self.options.local.labels else self.options.remote.labels;
        const ep = if (local) View.Endpoint{ .kind = .local_fs, .binding_id = self.options.local.endpoint.binding_id, .binding_generation = self.options.local.endpoint.binding_generation } else View.Endpoint{ .kind = .sftp, .binding_id = self.options.remote.endpoint.binding_id, .binding_generation = self.options.remote.endpoint.binding_generation };
        const selection: View.Selection = if (pane.selection) |value| value.value else .{ .keys = &.{}, .anchor = null, .focused_key = null };
        const writable = !self.closing and fresh(pane.state) and self.endpointLive(side) and (if (local) self.options.local.writable else self.options.remote.writable);
        return .{
            .stamp = .{ .owner = self.options.owner, .endpoint = ep, .request_id = pane.request_id, .directory_revision = pane.directory_revision },
            .selection_revision = pane.selection_revision,
            .title = labels.title,
            .subtitle = labels.subtitle,
            .badge = labels.badge,
            .resolved_path = pane.directory.?.path,
            .entries = pane.directory.?.entries,
            .selected_keys = selection.keys,
            .anchor = selection.anchor,
            .focused_key = selection.focused_key,
            .sort = pane.sort,
            .state = pane.state,
            .failure = pane.failure,
            .writable = writable,
            .can_transfer = !self.closing and fresh(pane.state) and self.options.callbacks.transfer != null,
            .can_mkdir = writable and self.options.callbacks.auxiliary != null and (if (pane.mkdir) |value| value.value.phase != .creating and value.value.phase != .refreshing else true),
            .can_back = pane.back.items.len != 0,
            .can_parent = !std.mem.eql(u8, pane.directory.?.path, "/"),
            .navigation_enabled = !self.closing and self.endpointLive(side),
        };
    }
    fn endpoint(self: *const Controller, side: Side) Endpoint {
        return if (side == .local) .{ .local_fs = self.options.local.endpoint } else .{ .sftp = self.options.remote.endpoint };
    }
    fn endpointLive(self: *const Controller, side: Side) bool {
        if (side == .local) return self.options.local.endpoint.eql(self.options.local.service.endpoint) and self.options.local.service.closeReceipt() != .released and !self.options.local.service.closing.load(.acquire);
        if (!self.options.remote.host.sessions.bindingIsLive(self.options.remote.directory)) return false;
        const state = self.options.remote.host.state(self.options.remote.directory) orelse return false;
        return state.owner.eql(self.options.owner) and state.endpoint.eql(self.options.remote.endpoint) and (state.phase == .connecting or state.phase == .ready);
    }
    fn find(self: *const Controller, key: operations.OperationKey, side: Side) ?usize {
        for (self.pending.items, 0..) |work, i| if (work.side == side and work.key.eql(key)) return i;
        return null;
    }
    fn cancel(self: *Controller, work: Work) void {
        _ = switch (work.side) {
            .local => self.options.local.service.cancel(work.key),
            .remote => self.options.remote.host.cancel(work.key),
        };
    }
    fn retireReady(self: *Controller) !void {
        var at: usize = 0;
        while (at < self.pending.items.len) {
            const work = &self.pending.items[at];
            if (!work.terminal) {
                at += 1;
                continue;
            }
            if (work.side == .remote) work.cleanup = receipt(self.options.remote.host.cleanupReceipt(work.key));
            if (work.cleanup != .released) {
                at += 1;
                continue;
            }
            switch (work.side) {
                .local => try self.options.local.journal.retire(work.key, .resources_released),
                .remote => try self.options.remote.host.retire(work.key),
            }
            var removed = self.pending.orderedRemove(at);
            removed.deinit(self.allocator);
        }
    }
    fn bump(self: *Controller) !void {
        self.revision = try identity.advance(self.revision);
    }
    fn updateHistory(self: *Controller, pane: *Pane, resolved: []const u8, mode: Mode) !void {
        const old = if (pane.directory) |directory| directory.path else return;
        if (std.mem.eql(u8, old, resolved)) return;
        switch (mode) {
            .navigate => {
                try pushPath(self.allocator, &pane.back, old);
                clearPaths(self.allocator, &pane.forward);
            },
            .back => {
                try pushPath(self.allocator, &pane.forward, old);
                if (pane.back.pop()) |value| self.allocator.free(value);
            },
            .forward => {
                try pushPath(self.allocator, &pane.back, old);
                if (pane.forward.pop()) |value| self.allocator.free(value);
            },
            .refresh => {},
        }
    }
    fn addHistory(self: *Controller, pane: *Pane, resolved: []const u8, succeeded: bool, failure: []const u8) !void {
        const copy = try self.allocator.dupe(u8, resolved);
        errdefer self.allocator.free(copy);
        const message = try self.allocator.dupe(u8, failure);
        errdefer self.allocator.free(message);
        try pane.history.append(self.allocator, .{ .path = copy, .succeeded = succeeded, .failure = message });
        if (pane.history.items.len > history_limit) {
            const removed = pane.history.orderedRemove(0);
            self.allocator.free(removed.path);
            self.allocator.free(removed.failure);
        }
    }
    fn releaseMemory(self: *Controller) void {
        for (&self.panes) |*pane| {
            if (pane.directory) |*directory| directory.arena.deinit();
            if (pane.selection) |*selection| selection.arena.deinit();
            if (pane.mkdir) |*value| value.arena.deinit();
            for (pane.history.items) |item| {
                self.allocator.free(item.path);
                self.allocator.free(item.failure);
            }
            pane.history.deinit(self.allocator);
            clearPaths(self.allocator, &pane.back);
            clearPaths(self.allocator, &pane.forward);
            pane.back.deinit(self.allocator);
            pane.forward.deinit(self.allocator);
        }
        for (self.pending.items) |*work| work.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.options_arena.deinit();
    }
};

fn receipt(value: anytype) ReleaseReceipt {
    return switch (value) {
        .released => .released,
        .awaiting => .awaiting,
        .unknown => .unknown,
    };
}
fn index(side: Side) usize {
    return if (side == .local) 0 else 1;
}
fn fresh(value: View.State) bool {
    return value == .ready or value == .empty;
}
fn path(value: []const u8) !void {
    if (value.len == 0 or value.len > fs.path_limit or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidPath;
}
fn absolute(value: []const u8) bool {
    return value.len > 0 and value[0] == '/' and std.mem.indexOfScalar(u8, value, 0) == null;
}
fn cloneLabels(a: std.mem.Allocator, value: Labels) !Labels {
    return .{ .title = try a.dupe(u8, value.title), .subtitle = try a.dupe(u8, value.subtitle), .badge = try a.dupe(u8, value.badge) };
}
fn navigationPath(a: std.mem.Allocator, side: Side, base: []const u8, requested: []const u8) ![]u8 {
    try path(requested);
    if (absolute(requested) or (side == .local and (std.mem.eql(u8, requested, "~") or std.mem.startsWith(u8, requested, "~/")))) return a.dupe(u8, requested);
    // Remote '~' is a literal relative name; never expand using this Mac HOME.
    const result = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ base, if (std.mem.endsWith(u8, base, "/")) @as([]const u8, "") else "/", requested });
    errdefer a.free(result);
    try path(result);
    return result;
}
fn parent(value: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, value, "/");
    const at = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return "/";
    return if (at == 0) "/" else trimmed[0..at];
}
fn validEntry(directory: []const u8, entry: anytype) bool {
    if (!absolute(entry.absolute_path) or entry.absolute_path.len > fs.path_limit or entry.raw_name.len == 0 or std.mem.indexOfScalar(u8, entry.raw_name, 0) != null or std.mem.indexOfScalar(u8, entry.raw_name, '/') != null or std.mem.eql(u8, entry.raw_name, ".") or std.mem.eql(u8, entry.raw_name, "..")) return false;
    const separator: usize = if (std.mem.endsWith(u8, directory, "/")) 0 else 1;
    if (entry.absolute_path.len != directory.len + separator + entry.raw_name.len or !std.mem.startsWith(u8, entry.absolute_path, directory) or !std.mem.endsWith(u8, entry.absolute_path, entry.raw_name)) return false;
    return separator == 0 or entry.absolute_path[directory.len] == '/';
}
fn convertEntry(a: std.mem.Allocator, entry: anytype) !Row {
    const kind: View.Kind = switch (entry.attributes.kind) {
        .file => .file,
        .directory => .directory,
        .symlink => .symlink,
        else => .unknown,
    };
    const modified = if (entry.attributes.modified_at) |seconds| try formatModified(a, seconds) else "";
    const label = if (entry.attributes.modified_at != null and entry.attributes.modified_at.? <= 253402300799) modified[0..16] else modified;
    return .{ .entry = .{
        .absolute_path = try a.dupe(u8, entry.absolute_path),
        .raw_name = try a.dupe(u8, entry.raw_name),
        .display_name = try a.dupe(u8, entry.display_name),
        .kind = kind,
        .size = entry.attributes.size,
        .modified_label = label,
        .modified_full = modified,
    }, .modified = entry.attributes.modified_at };
}
fn formatModified(a: std.mem.Allocator, seconds: u64) ![]const u8 {
    // std epoch calculations use a bounded Gregorian year. Preserve exact
    // server value for out-of-range metadata instead of wrapping the date.
    if (seconds > 253402300799) return std.fmt.allocPrint(a, "{d} s since Unix epoch (UTC)", .{seconds});
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const day = epoch.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{ yd.year, @backingInt(md.month), md.day_index + 1, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute() });
}
fn lessThan(sort_: View.Sort, a: Row, b: Row) bool {
    const order = switch (sort_.column) {
        .name => std.mem.order(u8, a.entry.raw_name, b.entry.raw_name),
        .size => optionalOrder(a.entry.size, b.entry.size),
        .modified => optionalOrder(a.modified, b.modified),
    };
    // Unknown metadata remains last in either direction.
    if (sort_.column == .size and (a.entry.size == null or b.entry.size == null) and a.entry.size != b.entry.size) return a.entry.size != null;
    if (sort_.column == .modified and (a.modified == null or b.modified == null) and a.modified != b.modified) return a.modified != null;
    if (order == .eq) return std.mem.lessThan(u8, a.entry.absolute_path, b.entry.absolute_path);
    return if (sort_.descending) order == .gt else order == .lt;
}
fn optionalOrder(a: ?u64, b: ?u64) std.math.Order {
    return if (a) |left| if (b) |right| std.math.order(left, right) else .lt else if (b != null) .gt else .eq;
}
fn contains(keys: []const []const u8, key: []const u8) bool {
    for (keys) |value| if (std.mem.eql(u8, value, key)) return true;
    return false;
}
fn equalKeys(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}
fn equalOptional(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |left| return if (b) |right| std.mem.eql(u8, left, right) else false;
    return b == null;
}
fn entryIndex(entries: []const View.Entry, key: []const u8) ?usize {
    for (entries, 0..) |entry, i| if (std.mem.eql(u8, entry.absolute_path, key)) return i;
    return null;
}
fn rowIndex(entries: []const Row, key: []const u8) ?usize {
    for (entries, 0..) |row, i| if (std.mem.eql(u8, row.entry.absolute_path, key)) return i;
    return null;
}
fn optionalExists(entries: []const View.Entry, key: ?[]const u8) bool {
    return if (key) |value| entryIndex(entries, value) != null else false;
}
fn isParent(entry: View.Entry) bool {
    return std.mem.eql(u8, entry.raw_name, "..") or std.mem.eql(u8, entry.raw_name, ".");
}
fn pushPath(a: std.mem.Allocator, stack: *std.ArrayList([]const u8), value: []const u8) !void {
    const copy = try a.dupe(u8, value);
    errdefer a.free(copy);
    try stack.append(a, copy);
    if (stack.items.len > history_limit) a.free(stack.orderedRemove(0));
}
fn clearPaths(a: std.mem.Allocator, stack: *std.ArrayList([]const u8)) void {
    for (stack.items) |value| a.free(value);
    stack.clearRetainingCapacity();
}
fn failureMessage(failure: anytype) []const u8 {
    const name = @tagName(failure);
    if (std.mem.eql(u8, name, "permission_denied")) return "没有权限读取此目录";
    if (std.mem.eql(u8, name, "not_found")) return "目录不存在";
    if (std.mem.eql(u8, name, "not_directory")) return "此路径不是目录";
    if (std.mem.eql(u8, name, "timeout")) return "目录读取超时，请重试";
    if (std.mem.eql(u8, name, "entry_limit")) return "目录项目超出读取上限";
    if (std.mem.eql(u8, name, "path_limit")) return "目录路径过长";
    return "目录读取失败，请重试";
}
fn mkdirCode(code: []const u8) MkdirFailure {
    return std.meta.stringToEnum(MkdirFailure, code) orelse if (std.mem.eql(u8, code, "connection") or std.mem.eql(u8, code, "subsystem_denied")) .unavailable else .io;
}
fn mkdirError(err: anyerror) MkdirFailure {
    return switch (err) {
        error.StaleBinding, error.Closing, error.FileServiceClosing, error.FileWorkspaceClosing => .unavailable,
        error.PermissionDenied, error.AccessDenied => .permission_denied,
        error.FileNotFound => .not_found,
        else => .io,
    };
}
