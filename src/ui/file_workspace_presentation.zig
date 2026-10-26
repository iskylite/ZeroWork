//! Main-thread SFTP presentation glue. Directory workers remain externally
//! owned; this module never polls a shared service or creates a terminal.
const std = @import("std");
const ui = @import("ui");
const Application = @import("application_host.zig").ApplicationHost;
const domain = @import("../host/session_host.zig");
const identity = @import("../host/identity.zig");
const operations = @import("../host/operation.zig");
const adapter = @import("../host/sftp_adapter.zig");
const binding = @import("../host/file_binding_host.zig");
pub const controller = @import("../host/file_workspace_controller.zig");
const View = @import("file_workspace_view.zig");
const Actions = @import("file_actions_view.zig");
const Copy = @import("file_copy_view.zig");
const Mkdir = @import("file_mkdir_view.zig");
const S = @import("file_workspace_styles.zig");
const promises = @import("../platform/file_promises.zig");
extern fn mkdtemp([*:0]u8) ?[*:0]u8;
pub const ExportStatus = enum { pending, succeeded, failed, cancelled };
pub const ExportCallbacks = struct {
    context: ?*anyopaque = null,
    start: ?*const fn (?*anyopaque, controller.FrozenTransfer) anyerror!u64 = null,
    poll: ?*const fn (?*anyopaque, u64) ExportStatus = null,
    cancel: ?*const fn (?*anyopaque, u64) void = null,
};
const PromisedDownload = struct { job: u64, index: u32, staging: []const u8, path: [:0]const u8 };
const Export = struct { arena: std.heap.ArenaAllocator, token: u64, intent: controller.FrozenTransfer, jobs: std.ArrayList(PromisedDownload) = .empty, completed: usize = 0, released: bool = false };

pub const Options = struct {
    app: *Application,
    file_host: *binding.FileBindingHost,
    local: controller.Local,
    callbacks: controller.Callbacks = .{},
    remote_writable: bool = false,
    confirm_transfer: ?Copy.Submit = null,
    exports: ExportCallbacks = .{},
    transfer_config: ?*const @import("../config/config.zig").Config = null,
};
const Entry = struct {
    host: *Presentation,
    owner: identity.SessionHandle,
    create_key: operations.OperationKey,
    target: domain.AttachmentTarget,
    model: controller.Controller,
    model_live: bool = true,
    attachment: ?domain.Attachment = null,
    root: ?*ui.Node = null,
    scope: ?*ui.Scope = null,
    view: ?*View.View = null,
    mkdir_views: [2]?*Mkdir.View = .{ null, null },
    copy_views: [2]?*Copy.View = .{ null, null },
    action_views: [2]?*Actions.View = .{ null, null },
    directory_recovery: ?struct { source: domain.SftpDirectoryRecovery, started: bool = false } = null,
    loading: ?*ui.Node = null,
    statuses: [2]?*ui.Node = .{ null, null },
    retry_disabled: [2]?*ui.Signal(bool) = .{ null, null },
    paint_colors: S.theme.Colors,
    last_revision: u64 = 0,
    exports: std.ArrayList(Export) = .empty,
    scope_disposed: bool = false,
    rollback: bool = false,
    release_requested: bool = false,
    released: bool = false,

    fn beginExport(raw: ?*anyopaque, request: View.ExternalExport) !bool {
        const self: *Entry = @ptrCast(@alignCast(raw orelse return error.FilePresentationUnavailable));
        if (!self.model_live or self.model.closing or self.scope_disposed or self.host.options.exports.start == null or self.host.options.exports.poll == null) return error.FileTransferUnavailable;
        const projection = self.model.projection() orelse return error.FileProjectionUnavailable;
        const source = projection.panes[1];
        const local = projection.panes[0];
        if (!std.meta.eql(source.stamp, request.source) or source.selection_revision != request.selection_revision or !self.owner.eql(request.source.owner)) return error.StaleFileSelection;
        if (request.paths.len == 0 or request.paths.len != source.selected_keys.len) return error.StaleFileSelection;
        var arena = std.heap.ArenaAllocator.init(self.host.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const paths = try a.alloc([]const u8, request.paths.len);
        const names = try a.alloc([*:0]const u8, request.paths.len);
        for (request.paths, 0..) |path, i| {
            var found = false;
            for (source.entries) |entry| if (std.mem.eql(u8, entry.absolute_path, path) and entry.kind == .file) {
                found = true;
                break;
            };
            if (!found) return error.OnlyRegularFilesCanBeDraggedOut;
            if (!std.mem.eql(u8, path, source.selected_keys[i])) return error.StaleFileSelection;
            paths[i] = try a.dupe(u8, path);
            names[i] = try a.dupeSentinel(u8, std.fs.path.basename(path), 0);
        }
        try self.exports.ensureUnusedCapacity(self.host.allocator, 1);
        const source_directory = try a.dupe(u8, source.resolved_path);
        const token = promises.begin(self.host.cx().native_window_id, names, request.x, request.y);
        if (token == 0) return error.NativeFileDragUnavailable;
        self.exports.appendAssumeCapacity(.{ .arena = arena, .token = token, .intent = .{
            .owner = self.owner,
            .source = .{ .stamp = source.stamp, .endpoint = .{ .sftp = self.model.options.remote.endpoint }, .selection_revision = source.selection_revision, .directory = source_directory },
            .destination = .{ .stamp = local.stamp, .endpoint = .{ .local_fs = self.model.options.local.endpoint }, .selection_revision = local.selection_revision, .directory = "" },
            .paths = paths,
        } });
        return true;
    }
    fn pollExports(self: *Entry) !bool {
        var at: usize = 0;
        while (at < self.exports.items.len) {
            const export_ = &self.exports.items[at];
            const a = export_.arena.allocator();
            const closing = !self.model_live or self.model.closing or self.scope_disposed;
            if (!export_.released and (closing or promises.status(export_.token) == 2)) {
                promises.release(export_.token);
                export_.released = true;
                if (self.host.options.exports.cancel) |cancel| for (export_.jobs.items) |job| cancel(self.host.options.exports.context, job.job);
            }
            if (!export_.released) while (true) {
                var index: u32 = 0;
                var destination: [8192]u8 = undefined;
                const ready = promises.poll(export_.token, &index, &destination);
                if (ready <= 0) break;
                if (index >= export_.intent.paths.len) {
                    _ = promises.complete(export_.token, index, null);
                    export_.completed += 1;
                    continue;
                }
                var scratch = "/tmp/zerowork-finder-XXXXXX".* ++ .{0};
                const staging = mkdtemp(&scratch) orelse {
                    _ = promises.complete(export_.token, index, null);
                    export_.completed += 1;
                    continue;
                };
                const directory = try a.dupe(u8, std.mem.span(staging));
                const staged_path = try std.fs.path.joinZ(a, &.{ directory, std.fs.path.basename(export_.intent.paths[index]) });
                var intent = export_.intent;
                intent.destination.directory = directory;
                intent.paths = export_.intent.paths[index .. index + 1];
                const job = self.host.options.exports.start.?(self.host.options.exports.context, intent) catch {
                    _ = promises.complete(export_.token, index, null);
                    export_.completed += 1;
                    std.Io.Dir.cwd().deleteTree(self.host.options.app.workspace.io, directory) catch {};
                    continue;
                };
                try export_.jobs.append(a, .{ .job = job, .index = index, .staging = directory, .path = staged_path });
            };
            var j: usize = 0;
            while (j < export_.jobs.items.len) {
                const job = export_.jobs.items[j];
                const state = self.host.options.exports.poll.?(self.host.options.exports.context, job.job);
                if (state == .pending) {
                    j += 1;
                    continue;
                }
                if (!export_.released) _ = promises.complete(export_.token, job.index, if (state == .succeeded) job.path.ptr else null);
                std.Io.Dir.cwd().deleteTree(self.host.options.app.workspace.io, job.staging) catch {};
                _ = export_.jobs.orderedRemove(j);
                export_.completed += 1;
            }
            if (export_.jobs.items.len == 0 and (export_.released or export_.completed == export_.intent.paths.len)) {
                if (!export_.released) promises.release(export_.token);
                export_.arena.deinit();
                _ = self.exports.orderedRemove(at);
            } else at += 1;
        }
        return self.exports.items.len > 0;
    }
    fn scopeDropped(self: *Entry) void {
        // Workspace owns an adopted scope and destroys its nodes exactly once.
        // The controller stays alive until its accepted requests really drain.
        self.scope_disposed = true;
        self.scope = null;
        self.root = null;
        self.view = null;
        self.mkdir_views = .{ null, null };
        self.action_views = .{ null, null };
        self.copy_views = .{ null, null };
        self.loading = null;
        self.statuses = .{ null, null };
        self.retry_disabled = .{ null, null };
        if (self.model_live) self.model.requestClose();
    }
    fn transfer(raw: ?*anyopaque, intent: controller.FrozenTransfer) !void {
        const self: *Entry = @ptrCast(@alignCast(raw orelse return error.FilePresentationUnavailable));
        if (!self.model_live or self.model.closing or self.scope_disposed) return error.FilePresentationClosing;
        if (self.host.options.confirm_transfer != null) {
            const side: usize = if (intent.destination.endpoint == .local_fs) 0 else 1;
            const view = self.copy_views[side] orelse return error.FilePresentationUnavailable;
            const defaults: Copy.Options = if (self.host.options.transfer_config) |config| .{ .resume_transfer = config.transfer.@"resume", .md5_check = config.transfer.verify_md5 } else .{};
            try view.open(intent, defaults);
            return;
        }
        const callback = self.host.options.callbacks.transfer orelse return error.UnsupportedFileAction;
        try callback(self.host.options.callbacks.context, intent);
    }
    fn confirmTransfer(raw: ?*anyopaque, intent: controller.FrozenTransfer, options: Copy.Options) !void {
        const self: *Entry = @ptrCast(@alignCast(raw orelse return error.FilePresentationUnavailable));
        if (!self.model_live or self.model.closing or self.scope_disposed or !self.owner.eql(intent.owner)) return error.FilePresentationClosing;
        const projection = self.model.projection() orelse return error.FileProjectionUnavailable;
        const local_endpoint = projection.panes[0].stamp.endpoint;
        const remote_endpoint = projection.panes[1].stamp.endpoint;
        const source = if (intent.source.endpoint == .local_fs) local_endpoint else remote_endpoint;
        const destination = if (intent.destination.endpoint == .local_fs) local_endpoint else remote_endpoint;
        if (!std.meta.eql(source, intent.source.stamp.endpoint) or !std.meta.eql(destination, intent.destination.stamp.endpoint)) return error.StaleBinding;
        const callback = self.host.options.confirm_transfer orelse return error.UnsupportedFileAction;
        try callback(self.host.options.callbacks.context, intent, options);
    }
    fn auxiliary(raw: ?*anyopaque, action: controller.Auxiliary) !void {
        const self: *Entry = @ptrCast(@alignCast(raw orelse return error.FilePresentationUnavailable));
        if (!self.model_live or self.model.closing or self.scope_disposed) return error.FilePresentationClosing;
        if (action == .recover) {
            try self.recoverDirectory(action.recover);
            return;
        }
        if (action == .context or action == .history) {
            const envelope = if (action == .context) action.context else action.history.envelope;
            const view = self.action_views[@backingInt(envelope.side)] orelse return error.FilePresentationUnavailable;
            try view.show(envelope, if (action == .history) action.history.entries else null);
            return;
        }
        if (action == .new_folder) {
            const view = self.mkdir_views[@backingInt(action.new_folder.side)] orelse return error.FilePresentationUnavailable;
            try view.open(action.new_folder);
            return;
        }
        const callback = self.host.options.callbacks.auxiliary orelse return error.UnsupportedFileAction;
        try callback(self.host.options.callbacks.context, action);
    }
    fn recoverDirectory(self: *Entry, envelope: View.Envelope) !void {
        if (envelope.side != .remote) return error.LocalFileServiceUnavailable;
        if (self.directory_recovery != null) return error.DirectoryRecoveryInProgress;
        const domain_host = self.host.options.app.sessions;
        const previous: domain.SftpDirectoryPair = .{ .directory = self.model.options.remote.directory, .file_read = switch (domain_host.queryService(self.owner, .file_read)) {
            .available => |handle| handle,
            else => if (domain_host.sftpDirectoryRecovery(self.owner)) |last| if (self.model.options.remote.directory.eql(last.bindings.directory)) last.bindings.file_read else last.previous.file_read else return error.FileSourceUnavailable,
        } };
        const source = try domain_host.beginSftpDirectoryRecovery(self.owner, previous);
        self.directory_recovery = .{ .source = source };
        try self.model.directoryRecoveryMessage("正在释放原目录连接；完成后请重新认证");
    }
    fn pollDirectoryRecovery(self: *Entry) !bool {
        const recovery = if (self.directory_recovery) |*value| value else return false;
        if (self.model.closing or self.scope_disposed) {
            if (!recovery.started) _ = try self.host.options.app.sessions.sftpDirectoryRecoveryReleased(recovery.source.bindings.directory, recovery.source.key, .released);
            self.directory_recovery = null;
            return false;
        }
        const source = recovery.source;
        const domain_host = self.host.options.app.sessions;
        const file_host = self.host.options.file_host;
        if (!recovery.started) {
            if (file_host.state(source.previous.directory)) |state| {
                if (state.cleanup == .unknown) {
                    _ = domain_host.sftpDirectoryPreviousReleased(self.owner, source.key, source.previous, .unknown);
                    try self.model.directoryRecoveryMessage("原目录连接释放未知，暂不能建立替代连接");
                }
                return true;
            }
            for (self.model.pending.items) |work| if (work.side == .remote) return true;
            if (!domain_host.sftpDirectoryPreviousReleased(self.owner, source.key, source.previous, .released)) return error.StaleDirectoryRecovery;
            _ = file_host.attachPreparing(self.owner, source.key, .{ .directory = source.bindings.directory, .file_read = source.bindings.file_read }) catch |err| {
                _ = try domain_host.sftpDirectoryRecoveryReleased(source.bindings.directory, source.key, .released);
                self.directory_recovery = null;
                try self.model.directoryRecoveryMessage(@errorName(err));
                return false;
            };
            recovery.started = true;
            try self.model.directoryRecoveryMessage("正在重新认证原 SFTP 目录连接");
        }
        const state = file_host.state(source.bindings.directory);
        if (state) |physical| {
            if (physical.phase == .ready) {
                if (!try domain_host.sftpDirectoryRecoveryReady(self.owner, source.key, source.bindings)) return error.StaleDirectoryRecovery;
                try self.model.rebindRemote(source.previous.directory, source.bindings, physical.endpoint);
                self.directory_recovery = null;
                return false;
            }
            if (physical.phase == .cleanup_unknown) try self.model.directoryRecoveryMessage("新目录连接释放未知；原列表仍保留");
            return true;
        }
        if (domain_host.sftpDirectoryRecovery(self.owner)) |latest| if (latest.key.eql(source.key) and latest.cleanup == .released) {
            self.directory_recovery = null;
            try self.model.directoryRecoveryMessage("目录恢复未完成；可再次显式恢复，原列表仍保留");
            return false;
        };
        return true;
    }
    fn retry(self: *Entry, side: View.Side) void {
        if (!self.model_live or self.model.closing or self.scope_disposed) return;
        self.model.retryInitial(side) catch |err| {
            if (self.statuses[@backingInt(side)]) |node| node.setTextContent(self.host.cx().allocator, @errorName(err)) catch {};
        };
        self.host.cx().requestRedraw();
    }
    fn retryLocal(self: *Entry) void {
        self.retry(.local);
    }
    fn retryRemote(self: *Entry) void {
        self.retry(.remote);
    }
};

/// Stable allocation: adapter hooks and entry scopes retain this pointer.
/// AppHost, FileBindingHost and local service/journal outlive this owner.
pub const Presentation = struct {
    allocator: std.mem.Allocator,
    options: Options,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(*Entry) = .empty,
    shutting_down: bool = false,
    ticking: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Options) !*Presentation {
        if (options.file_host.sessions != options.app.sessions) return error.HostChanged;
        if (!options.local.endpoint.eql(options.local.service.endpoint) or options.local.endpoint.resource_owner != null) return error.InvalidLocalEndpoint;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var copy = options;
        copy.local.initial_path = try arena.allocator().dupe(u8, options.local.initial_path);
        copy.local.verified_path = if (options.local.verified_path) |value| try arena.allocator().dupe(u8, value) else null;
        copy.local.labels = .{ .title = try arena.allocator().dupe(u8, options.local.labels.title), .subtitle = try arena.allocator().dupe(u8, options.local.labels.subtitle), .badge = try arena.allocator().dupe(u8, options.local.labels.badge) };
        const self = try allocator.create(Presentation);
        self.* = .{ .allocator = allocator, .options = copy, .arena = arena };
        return self;
    }
    pub fn hooks(self: *Presentation) adapter.PresentationHooks {
        return .{ .context = self, .install = installHook, .release = releaseHook, .rollback = rollbackHook };
    }
    fn cx(self: *Presentation) *ui.Cx {
        return self.options.app.workspace.cx;
    }

    /// Called only at the app's layout safe point. The root scheduler owns
    /// local.Service.poll and FileBindingHost.safeTick, then routes each result.
    pub fn safeTick(self: *Presentation) !bool {
        if (self.ticking) return error.ReentrantFilePresentation;
        self.ticking = true;
        defer self.ticking = false;
        var active = false;
        for (self.entries.items) |entry| {
            active = try entry.pollExports() or active;
            if (entry.released) continue;
            if (entry.model_live) {
                const state = self.options.app.sessions.queryState(entry.owner);
                if (self.shutting_down or state == null or !state.?.create_operation.eql(entry.create_key) or state.?.lifecycle == .closing or state.?.lifecycle == .closed or state.?.lifecycle == .cleanup_unknown or state.?.lifecycle == .failed) entry.model.requestClose();
                _ = try entry.model.pump();
                active = try entry.pollDirectoryRecovery() or active;
                if (!entry.model.closing and !entry.scope_disposed and !entry.rollback) try self.publish(entry);
            }
            const receipt = try self.advanceClose(entry);
            if (receipt != .released or !entry.released) active = active or entry.rollback or entry.release_requested or entry.model.closing or entry.model.pending.items.len > 0;
        }
        return active;
    }

    /// Borrowed result; false leaves its ownership with another root consumer.
    /// Never deinitializes the caller's OwnedResult or consumes unrelated keys.
    pub fn acceptLocal(self: *Presentation, result: controller.fs.Result) !bool {
        for (self.entries.items) |entry| {
            if (!entry.model_live or entry.released) continue;
            if (try entry.model.acceptLocal(result)) {
                self.cx().requestRedraw();
                return true;
            }
        }
        return false;
    }
    pub fn shutdownStep(self: *Presentation) domain.CloseReceipt {
        self.shutting_down = true;
        var result: domain.CloseReceipt = .released;
        for (self.entries.items) |entry| {
            if (entry.released) continue;
            if (entry.model_live) entry.model.requestClose();
            result = combine(result, if (entry.model_live) toDomain(entry.model.closeReceipt()) else .awaiting);
            // A released directory request alone does not release its view.
            if (!entry.released) result = combine(result, .awaiting);
        }
        return result;
    }
    pub fn deinit(self: *Presentation) error{Busy}!void {
        for (self.entries.items) |entry| if (!entry.released or entry.model_live or !entry.scope_disposed) return error.Busy;
        for (self.entries.items) |entry| if (entry.exports.items.len > 0) return error.Busy;
        for (self.entries.items) |entry| {
            entry.exports.deinit(self.allocator);
            self.allocator.destroy(entry);
        }
        self.entries.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    /// Diagnostic lookup; callers must not retain it beyond this presentation.
    pub fn modelFor(self: *Presentation, owner: identity.SessionHandle) ?*controller.Controller {
        const entry = self.find(owner) orelse return null;
        return if (entry.model_live and !entry.released) &entry.model else null;
    }
    pub fn contentFor(self: *Presentation, owner: identity.SessionHandle) ?*ui.Node {
        const entry = self.find(owner) orelse return null;
        return if (!entry.scope_disposed and !entry.released) entry.root else null;
    }
    pub fn transferScopeFor(self: *Presentation, owner: identity.SessionHandle) ?*ui.Scope {
        const entry = self.find(owner) orelse return null;
        if (entry.scope_disposed or entry.released) return null;
        return if (entry.view) |view| view.scope else null;
    }
    pub fn transferSlotFor(self: *Presentation, owner: identity.SessionHandle, side: View.Side) ?*ui.Node {
        const entry = self.find(owner) orelse return null;
        if (entry.scope_disposed or entry.released) return null;
        return if (entry.view) |view| view.transferSlot(side) else null;
    }
    /// File cards align with the sidebar; the assistant panel uses the full content bounds.
    pub fn assistantBounds(self: *Presentation, owner: identity.SessionHandle) ?ui.ComputedRect {
        const entry = self.find(owner) orelse return null;
        if (entry.scope_disposed or entry.released) return null;
        const root = entry.root orelse return null;
        return if (entry.view) |view| view.root.globalRect() else root.globalRect();
    }
    /// The app's global theme/material change updates loading and ready views.
    pub fn retheme(self: *Presentation) void {
        for (self.entries.items) |entry| {
            if (entry.scope_disposed or entry.released) continue;
            if (entry.loading) |node| S.repaint(node, entry.paint_colors);
            if (entry.view) |view| view.retheme();
            entry.paint_colors = S.theme.current();
        }
        self.cx().requestRedraw();
    }

    fn installHook(raw: *anyopaque, source: adapter.Presentation) !domain.Attachment {
        const self: *Presentation = @ptrCast(@alignCast(raw));
        return self.install(source);
    }
    fn install(self: *Presentation, source: adapter.Presentation) !domain.Attachment {
        if (self.shutting_down) return error.FilePresentationClosing;
        if (self.find(source.owner) != null) return error.FilePresentationAlreadyExists;
        const app = self.options.app;
        const state = app.sessions.queryState(source.owner) orelse return error.StaleSession;
        if (!state.create_operation.eql(source.create_key) or state.lifecycle != .ready) return error.FileSessionNotReady;
        if (!std.meta.eql(source.target, state.target) or source.target.window_id != app.window_id or source.target.workspace_id != app.workspace_id) return error.WrongAttachmentTarget;
        inline for (.{ .{ source.handles.directory, domain.ServiceKind.directory }, .{ source.handles.file_read, domain.ServiceKind.file_read }, .{ source.handles.transfer, domain.ServiceKind.transfer } }) |pair| {
            switch (app.sessions.queryService(source.owner, pair[1])) {
                .available => |live| if (!live.eql(pair[0])) return error.StaleServiceHandle,
                else => return error.FileSessionNotReady,
            }
        }
        const frozen = try app.fileSource(source.owner, source.create_key);
        var subtitle_buffer: [512]u8 = undefined;
        const subtitle = try std.fmt.bufPrint(&subtitle_buffer, "{s}@{s}:{d}", .{ frozen.host.user, frozen.host.host, frozen.host.port });
        var badge_buffer: [64]u8 = undefined;
        const badge = try std.fmt.bufPrint(&badge_buffer, "SFTP #{d}", .{@backingInt(source.owner.session_id)});
        const entry = try self.allocator.create(Entry);
        var adopted = false;
        errdefer if (!adopted) self.allocator.destroy(entry);
        entry.* = .{ .host = self, .owner = source.owner, .create_key = source.create_key, .target = source.target, .paint_colors = S.theme.current(), .model = try controller.Controller.init(self.allocator, .{
            .owner = source.owner,
            .local = self.options.local,
            .remote = .{ .host = self.options.file_host, .directory = source.handles.directory, .endpoint = source.initial_directory.endpoint, .initial_path = source.initial_directory.requested_path, .labels = .{ .title = frozen.host.name, .subtitle = subtitle, .badge = badge }, .writable = self.options.remote_writable },
            .callbacks = .{ .context = entry, .transfer = if (self.options.callbacks.transfer != null) Entry.transfer else null, .auxiliary = Entry.auxiliary },
        }) };
        errdefer if (!adopted) {
            entry.model.requestClose();
            entry.model.deinit() catch {};
        };
        try entry.model.seedRemote(.{ .endpoint = source.initial_directory.endpoint, .key = source.initial_directory.key, .request_id = source.initial_directory.request_id, .directory_revision = source.initial_directory.directory_revision, .requested_path = source.initial_directory.requested_path, .resolved_path = source.initial_directory.resolved_path, .entries = source.initial_directory.entries, .failure = source.initial_directory.failure, .cleanup = source.initial_directory.cleanup, .retired = source.initial_directory.retired });
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        self.entries.appendAssumeCapacity(entry);
        adopted = true;
        // From here on a synchronous failure retains a rollback owner until
        // any accepted local request has delivered its true release receipt.
        errdefer {
            entry.rollback = true;
            entry.model.requestClose();
            self.cx().requestRedraw();
        }
        try entry.model.start();
        const scope = try app.workspace.scope.childScope();
        entry.scope = scope;
        try scope.onCleanup(Entry, entry, Entry.scopeDropped);
        const root = try ui.box(self.cx(), .{ .width = .fill(), .height = .fill(), .direction = .column, .min_width = 0, .min_height = 0 }, .{});
        root.meta.ownership.meta.test_id = "files.presentation";
        entry.root = root;
        entry.loading = try ui.boxStyled(self.cx(), S.root, .{});
        try root.appendChild(self.allocator, entry.loading.?);
        inline for (0..2) |i| {
            const card = try ui.boxStyled(self.cx(), S.card, .{});
            const title = try ui.textStyled(self.cx(), S.title, "");
            try title.setTextContent(self.allocator, if (i == 0) entry.model.options.local.labels.title else entry.model.options.remote.labels.title);
            try card.appendChild(self.allocator, title);
            const status = try ui.textStyled(self.cx(), S.secondary, "");
            status.meta.ownership.meta.test_id = if (i == 0) "files.initial.local.status" else "files.initial.remote.status";
            try card.appendChild(self.allocator, status);
            entry.statuses[i] = status;
            entry.retry_disabled[i] = try scope.createSignal(bool, true);
            const retry = try ui.widgets.Button(.{ .label = "重新读取", .variant = .secondary, .disabled = entry.retry_disabled[i].?, .on_click = self.cx().on(Entry, entry, if (i == 0) Entry.retryLocal else Entry.retryRemote) }).mount(scope, self.cx());
            retry.meta.ownership.meta.test_id = if (i == 0) "files.initial.local.retry" else "files.initial.remote.retry";
            try card.appendChild(self.allocator, retry);
            try entry.loading.?.appendChild(self.allocator, card);
        }
        entry.view = try View.View.mount(self.cx(), scope, entry.model.viewCallbacks());
        entry.view.?.callbacks.export_context = entry;
        entry.view.?.callbacks.export_files = Entry.beginExport;
        try root.appendChild(self.allocator, entry.view.?.root);
        for (entry.view.?.panes, 0..) |pane, i| {
            entry.copy_views[i] = try Copy.View.mount(self.cx(), scope, pane, entry, Entry.confirmTransfer);
            entry.mkdir_views[i] = try Mkdir.View.mount(self.cx(), scope, pane, &entry.model);
            entry.action_views[i] = try Actions.View.mount(self.cx(), scope, pane, &entry.model);
            try root.appendChild(self.allocator, entry.action_views[i].?.root);
        }
        try self.publish(entry);
        const attachment = try app.attachFileSession(source.owner, source.create_key, root, scope);
        entry.attachment = attachment;
        return attachment;
    }
    fn publish(self: *Presentation, entry: *Entry) !void {
        if (entry.scope_disposed or entry.view == null) return;
        for (entry.action_views) |optional| if (optional) |view| try view.sync();
        for (entry.mkdir_views) |optional| if (optional) |view| try view.sync();
        if (entry.model.projection()) |projection| {
            if (projection.revision != entry.last_revision) {
                try entry.view.?.update(projection);
                entry.last_revision = projection.revision;
            }
            entry.loading.?.setDisplay(.none);
        } else {
            entry.loading.?.setDisplay(.flex);
            inline for (0..2) |i| {
                const state = entry.model.paneStatus(@fromBackingInt(@intCast(i)));
                const text = if (state.failure.len > 0) state.failure else if (state.state == .loading) "正在读取目录…" else if (state.state == .empty) "目录为空" else "目录已读取";
                if (entry.statuses[i]) |node| try node.setTextContent(self.allocator, text);
                if (entry.retry_disabled[i]) |signal| signal.set(entry.model.closing or state.state == .loading or entry.model.panes[i].directory != null);
            }
        }
    }
    fn releaseHook(raw: *anyopaque, owner: identity.SessionHandle, attachment: domain.Attachment, key: operations.OperationKey) domain.CloseReceipt {
        const self: *Presentation = @ptrCast(@alignCast(raw));
        const entry = self.find(owner) orelse return .unknown;
        if (entry.attachment == null or !std.meta.eql(entry.attachment.?, attachment) or key.owner != .session or !key.owner.session.eql(owner)) return .unknown;
        const state = self.options.app.sessions.queryState(owner);
        if (!key.eql(entry.create_key) and (state == null or state.?.close_operation == null or !state.?.close_operation.?.eql(key))) return .unknown;
        if (entry.released) return .released;
        entry.release_requested = true;
        entry.model.requestClose();
        self.cx().requestRedraw();
        return self.advanceClose(entry) catch .unknown;
    }
    fn rollbackHook(raw: *anyopaque, owner: identity.SessionHandle, key: operations.OperationKey) domain.CloseReceipt {
        const self: *Presentation = @ptrCast(@alignCast(raw));
        if (key.owner != .session or !key.owner.session.eql(owner)) return .unknown;
        const entry = self.find(owner) orelse return .released;
        if (!entry.create_key.eql(key) or !entry.rollback or entry.attachment != null) return .unknown;
        if (entry.released) return .released;
        entry.model.requestClose();
        self.cx().requestRedraw();
        return self.advanceClose(entry) catch .unknown;
    }
    fn advanceClose(self: *Presentation, entry: *Entry) !domain.CloseReceipt {
        if (entry.released) return .released;
        if (!entry.rollback and !entry.release_requested and !entry.scope_disposed) return .awaiting;
        if (!entry.model.closing) entry.model.requestClose();
        const receipt = toDomain(entry.model.closeReceipt());
        if (receipt != .released or entry.model.pending.items.len != 0) return if (receipt == .released) .awaiting else receipt;
        if (entry.attachment) |attachment| {
            if (!entry.scope_disposed) {
                const workspace = self.options.app.workspace;
                const at = workspace.tabIndexById(attachment.tab_id) orelse return .unknown;
                const tab = workspace.tabs.items[at];
                if (!tab.content_owner.eql(.{ .session = entry.owner }) or tab.generation != entry.owner.generation or tab.root != entry.root or tab.file_scope != entry.scope or tab.terminal != null or !std.meta.eql(attachment.target, entry.target)) return .unknown;
                workspace.receiveCloseReceipt(attachment.tab_id, .{ .session = entry.owner }, true);
                return .awaiting;
            }
            if (self.options.app.workspace.tabIndexById(attachment.tab_id) != null) return .awaiting;
        } else {
            const root = entry.root;
            if (entry.scope) |scope| scope.dispose();
            entry.scope = null;
            entry.scope_disposed = true;
            entry.root = null;
            if (root) |node| {
                if (node.parent != null) return error.UnexpectedFileContentOwner;
                self.cx().destroyDetached(node);
            }
        }
        try entry.model.deinit();
        entry.model_live = false;
        entry.released = true;
        return .released;
    }
    fn find(self: *Presentation, owner: identity.SessionHandle) ?*Entry {
        for (self.entries.items) |entry| if (entry.owner.eql(owner)) return entry;
        return null;
    }
};
fn toDomain(value: controller.ReleaseReceipt) domain.CloseReceipt {
    return switch (value) {
        .released => .released,
        .awaiting => .awaiting,
        .unknown => .unknown,
    };
}
fn combine(a: domain.CloseReceipt, b: domain.CloseReceipt) domain.CloseReceipt {
    if (a == .unknown or b == .unknown) return .unknown;
    if (a == .awaiting or b == .awaiting) return .awaiting;
    return .released;
}
