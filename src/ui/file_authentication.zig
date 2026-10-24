//! Original-operation authentication for independent file connections. The UI
//! owns Context allocation/reclamation; native workers only use their bridges
//! and delegate connector IO, then publish the actual destruction receipt.
const std = @import("std");
const sessions = @import("../host/session_host.zig");
const files = @import("../host/file_binding_host.zig");
const route = @import("../host/file_route_factory.zig");
const identity = @import("../host/identity.zig");
const hosts = @import("../config/hosts.zig");
pub const auth = @import("../proto/ssh/auth_challenge.zig");
pub const host_key = @import("host_key_confirmation.zig");
const ssh = @import("../proto/ssh/session.zig");
const Snapshot = @import("session_lifecycle.zig").Snapshot;
const TotpPrefill = @import("../proto/ssh/totp_prefill.zig");
pub const Receipt = files.readonly.ReleaseReceipt;
pub const Options = struct {
    library: *const ssh.Library,
    known_hosts_path: []const u8,
    presentation: auth.Presentation = .protected_form,
    presentation_config_revision: u64 = 1,
    saved_config: ?*const @import("../config/config.zig").Config = null,
    totp_autofill: bool = false,
    timeout_ms: u32 = 15_000,
};
const context_limit = 32;
const Context = struct {
    source: Snapshot(files.Source),
    presentation: auth.Presentation,
    presentation_config_revision: u64,
    totp_autofill: bool,
    counter: auth.RequestCounter = .{},
    host_bridge: host_key.Bridge = .{},
    auth_bridge: auth.InteractiveBridge = .{},
    delegate: files.readonly.Connector,
    started: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    native_receipt: std.atomic.Value(u8) = .init(@backingInt(Receipt.awaiting)),
    closed: std.atomic.Value(bool) = .init(false),

    fn cancel(self: *Context) void {
        self.cancelled.store(true, .release);
        self.host_bridge.cancel();
        self.auth_bridge.cancel();
    }
    fn connect(raw: *anyopaque, cancelled: *const std.atomic.Value(bool)) !ssh.Session {
        const self: *Context = @ptrCast(@alignCast(raw));
        if (self.started.swap(true, .acq_rel)) return error.ConnectorAlreadyStarted;
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        return self.delegate.connect_fn(self.delegate.ctx, cancelled);
    }
    fn close(raw: *anyopaque, session: ?*ssh.Session) Receipt {
        const self: *Context = @ptrCast(@alignCast(raw));
        const receipt = self.delegate.close_fn(self.delegate.ctx, session);
        self.native_receipt.store(@backingInt(receipt), .release);
        return receipt;
    }
    fn destroy(raw: *anyopaque) void {
        const self: *Context = @ptrCast(@alignCast(raw));
        // A premature/double call cannot turn unknown cleanup into released.
        if (self.closed.load(.acquire)) return;
        if (self.started.load(.acquire) and self.native_receipt.load(.acquire) != @backingInt(Receipt.released)) return;
        self.delegate.deinit_fn(self.delegate.ctx);
        self.cancel();
        // No access to Context follows this publication; UI collect owns free.
        self.closed.store(true, .release);
    }
};

pub const FileAuthentication = struct {
    allocator: std.mem.Allocator,
    sessions: *sessions.SessionHost,
    options: Options,
    arena: std.heap.ArenaAllocator,
    contexts: std.ArrayList(*Context) = .empty,
    shutting_down: bool = false,

    pub fn init(allocator: std.mem.Allocator, domain: *sessions.SessionHost, options: Options) !*FileAuthentication {
        if (!std.fs.path.isAbsolute(options.known_hosts_path) or options.presentation_config_revision == 0 or options.timeout_ms == 0) return error.InvalidFileAuthenticationOptions;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var frozen = options;
        frozen.known_hosts_path = try arena.allocator().dupe(u8, options.known_hosts_path);
        const self = try allocator.create(FileAuthentication);
        self.* = .{ .allocator = allocator, .sessions = domain, .options = frozen, .arena = arena };
        return self;
    }
    pub fn factory(self: *FileAuthentication) files.Factory {
        return .{ .context = self, .prepare = prepare, .discard = discard };
    }
    /// Safe-point reconciliation; this performs no native IO or worker join.
    /// Source/bridges outlive the delegate's actual close and deinit callback.
    pub fn collect(self: *FileAuthentication) !bool {
        var index: usize = 0;
        while (index < self.contexts.items.len) {
            const context = self.contexts.items[index];
            if (context.closed.load(.acquire)) {
                _ = self.contexts.orderedRemove(index);
                context.source.deinit();
                self.allocator.destroy(context);
                continue;
            }
            if (!self.current(context)) context.cancel();
            index += 1;
        }
        return self.contexts.items.len != 0;
    }
    pub fn shutdownStep(self: *FileAuthentication) Receipt {
        self.shutting_down = true;
        var receipt: Receipt = .released;
        for (self.contexts.items) |context| {
            context.cancel();
            if (!context.closed.load(.acquire)) {
                receipt = if (context.native_receipt.load(.acquire) == @backingInt(Receipt.unknown)) .unknown else if (receipt == .released) .awaiting else receipt;
            }
        }
        return receipt;
    }
    pub fn deinit(self: *FileAuthentication) error{Busy}!void {
        for (self.contexts.items) |context| if (!context.closed.load(.acquire)) return error.Busy;
        for (self.contexts.items) |context| {
            context.source.deinit();
            self.allocator.destroy(context);
        }
        self.contexts.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn pendingAuthentication(self: *FileAuthentication) ?auth.Snapshot {
        for (self.contexts.items) |context| {
            if (!self.current(context)) {
                context.cancel();
                continue;
            }
            if (self.pending(context)) |snapshot| return snapshot;
        }
        return null;
    }
    pub fn submitAuthentication(self: *FileAuthentication, request: auth.RequestIdentity, reply: auth.Reply) !void {
        const context = self.find(request) orelse return error.StaleAuthentication;
        switch (reply) {
            .answers => try context.auth_bridge.submit(request, reply),
            else => if (!context.host_bridge.decideScoped(request, reply)) return error.StaleAuthentication,
        }
    }
    pub fn authenticationTotp(self: *FileAuthentication, request: auth.RequestIdentity, now: TotpPrefill.Time) !?TotpPrefill.Suggestion {
        const context = self.find(request) orelse return null;
        const snapshot = context.auth_bridge.snapshot() orelse return null;
        return TotpPrefill.suggestForSpec(&snapshot, request, context.source.value.spec, context.totp_autofill, now);
    }
    pub fn cancelAuthentication(self: *FileAuthentication, request: auth.RequestIdentity) bool {
        const context = self.find(request) orelse return false;
        context.cancel();
        // Auth keys belong to the physical file open. Only the original
        // creating file-workspace operation is cancelled; an auxiliary file
        // open can never cancel an attached original terminal.
        if (self.sessions.queryState(context.source.value.owner)) |state| {
            const manifest = self.sessions.manifestFor(context.source.value.owner) orelse return true;
            if (manifest.integration.directory_recovery and state.create_operation.eql(context.source.value.create_key) and (state.lifecycle == .creating or state.lifecycle == .ready)) _ = self.sessions.cancel(context.source.value.create_key) catch false;
        }
        return true;
    }
    pub fn authenticationHostFor(self: *FileAuthentication, request: auth.RequestIdentity) ?hosts.HostConfig {
        const context = self.find(request) orelse return null;
        return metadata(context.source.value.spec, request.hop_index);
    }
    pub fn authenticationHostKey(self: *FileAuthentication, request: auth.RequestIdentity) ?host_key.Request {
        const context = self.find(request) orelse return null;
        const observed = context.host_bridge.lastSnapshot() orelse return null;
        const key = observed.operation_key orelse return null;
        if (!key.eql(request.key) or observed.hop_index != request.hop_index) return null;
        return observed;
    }

    fn current(self: *FileAuthentication, context: *Context) bool {
        if (self.shutting_down or context.closed.load(.acquire) or context.cancelled.load(.acquire)) return false;
        if (context.source.value.retained_owner) |id| return self.sessions.retainedTransferOperationIsCurrent(id, context.source.value.owner, context.source.value.open_key);
        if (context.source.value.create_key.eql(context.source.value.open_key)) return self.sessions.auxiliaryTransferOperationIsCurrent(context.source.value.owner, context.source.value.open_key);
        const state = self.sessions.queryState(context.source.value.owner) orelse return false;
        if (!state.create_operation.eql(context.source.value.create_key)) return false;
        return state.lifecycle == .creating or state.lifecycle == .ready or state.lifecycle == .attached;
    }
    fn pending(self: *FileAuthentication, context: *Context) ?auth.Snapshot {
        _ = self;
        const source = context.source.value;
        if (context.host_bridge.snapshot()) |request| {
            const key = request.operation_key orelse return null;
            const host = metadata(source.spec, request.hop_index) orelse return null;
            if (!key.eql(source.open_key) or !std.mem.eql(u8, host.host, request.hostSlice()) or host.port != request.port or host.user.len > 256) return null;
            var snapshot: auth.Snapshot = .{
                .identity = .{ .key = key, .hop_index = request.hop_index, .request_id = request.generation },
                .source_owner = request.source_owner,
                .kind = if (request.status == .changed) .host_key_changed else .host_key_unknown,
                .presentation = .protected_form,
                .presentation_config_revision = context.presentation_config_revision,
                .expires_at_ns = null,
                .port = request.port,
                .host_len = request.host_len,
                .user_len = host.user.len,
            };
            @memcpy(snapshot.host[0..request.host_len], request.hostSlice());
            @memcpy(snapshot.user[0..host.user.len], host.user);
            return snapshot;
        }
        const snapshot = context.auth_bridge.snapshot() orelse return null;
        if (!snapshot.identity.key.eql(source.open_key) or snapshot.state == .completed or snapshot.state == .cancelled) return null;
        const host = metadata(source.spec, snapshot.identity.hop_index) orelse return null;
        const endpoint = snapshot.endpoint();
        if (!std.mem.eql(u8, host.host, endpoint.host) or !std.mem.eql(u8, host.user, endpoint.user) or host.port != endpoint.port) return null;
        return snapshot;
    }
    fn find(self: *FileAuthentication, request: auth.RequestIdentity) ?*Context {
        for (self.contexts.items) |context| {
            if (!context.source.value.open_key.eql(request.key) or !self.current(context)) continue;
            const snapshot = self.pending(context) orelse return null;
            if (snapshot.identity.eql(request)) return context;
        }
        return null;
    }
    fn prepare(raw: *anyopaque, source: files.Source) !files.readonly.Connector {
        const self: *FileAuthentication = @ptrCast(@alignCast(raw));
        if (self.shutting_down) return error.FileAuthenticationClosing;
        if (source.retained_owner) |id| {
            if (!source.ownsOperation(source.create_key) or !source.ownsOperation(source.open_key)) return error.InvalidFileOperation;
            if (!self.sessions.retainedTransferOperationIsCurrent(id, source.owner, source.open_key) or !source.create_key.eql(source.open_key)) return error.StaleRetainedOperation;
        } else if (source.create_key.eql(source.open_key) and self.sessions.auxiliaryTransferOperationIsCurrent(source.owner, source.open_key)) {
            if (!source.ownsOperation(source.create_key)) return error.InvalidFileOperation;
        } else {
            const state = self.sessions.queryState(source.owner) orelse return error.StaleSession;
            if (!state.create_operation.eql(source.create_key) or (state.lifecycle != .creating and state.lifecycle != .ready and state.lifecycle != .attached)) return error.StaleCreateOperation;
            if (!source.ownsOperation(source.create_key) or !source.ownsOperation(source.open_key) or source.open_key.eql(source.create_key) or source.open_key.attempt_id != source.create_key.attempt_id) return error.InvalidFileOperation;
        }
        var original_open = false;
        for (self.sessions.journal.records.items) |record| if (record.key.eql(source.open_key) and !record.terminal and !record.cleanup_released) {
            original_open = true;
            break;
        };
        if (!original_open) return error.StaleFileOperation;
        if (self.contexts.items.len == context_limit) return error.FileAuthenticationLimit;
        for (self.contexts.items) |context| if (context.source.value.open_key.eql(source.open_key)) return error.DuplicateFileOperation;
        var original = source;
        if (source.retained_owner) |id| {
            original.spec = self.sessions.retainedTransferSource(id, source.owner) orelse return error.UnknownRetainedTransfer;
        } else {
            original.spec = self.sessions.engineSpec(source.owner) orelse return error.StaleSession;
        }
        try self.contexts.ensureUnusedCapacity(self.allocator, 1);
        var frozen = try Snapshot(files.Source).init(self.allocator, original);
        errdefer frozen.deinit();
        const context = try self.allocator.create(Context);
        errdefer self.allocator.destroy(context);
        const saved = self.options.saved_config;
        context.* = .{
            .source = frozen,
            .presentation = if (saved) |config| (if (config.ssh.otp_modal) .otp_modal else .protected_form) else self.options.presentation,
            .presentation_config_revision = if (saved) |config| config.config_revision else self.options.presentation_config_revision,
            .totp_autofill = if (saved) |config| config.ssh.totp_autofill else self.options.totp_autofill,
            .delegate = undefined,
        };
        context.host_bridge.request_counter = &context.counter;
        context.auth_bridge.request_counter = &context.counter;
        var native_factory: route.SourceFactory = .{
            .library = self.options.library,
            .known_hosts_path = self.options.known_hosts_path,
            .host_key_observer = .{ .ctx = &context.host_bridge, .callback = host_key.Bridge.observer },
            .auth_interaction = .{ .bridge = &context.auth_bridge, .presentation = context.presentation, .presentation_config_revision = context.presentation_config_revision },
            .timeout_ms = self.options.timeout_ms,
        };
        context.delegate = try native_factory.interface().prepare(&native_factory, context.source.value);
        self.contexts.appendAssumeCapacity(context);
        return .{ .key = source.open_key, .ctx = context, .connect_fn = Context.connect, .close_fn = Context.close, .deinit_fn = Context.destroy };
    }
    fn discard(raw: *anyopaque, connector: files.readonly.Connector) void {
        const self: *FileAuthentication = @ptrCast(@alignCast(raw));
        for (self.contexts.items) |context| if (@intFromPtr(context) == @intFromPtr(connector.ctx) and context.source.value.open_key.eql(connector.key)) {
            if (!context.started.load(.acquire)) Context.destroy(context);
            return;
        };
    }
};

fn metadata(spec: sessions.SessionCreateSpec, hop_index: usize) ?hosts.HostConfig {
    const hops = switch (spec) {
        .local, .plugin => return null,
        .saved => |saved| saved.route_snapshot,
        .temporary_ssh => |temporary| temporary.route_snapshot,
    };
    var owner: ?identity.AssetOwner = null;
    var name: []const u8 = "";
    var protocol: hosts.Protocol = .ssh;
    const remote: sessions.RemoteConfig = if (hop_index < hops.len) blk: {
        const hop = hops[hop_index];
        owner = hop.owner;
        name = hop.display_name;
        break :blk .{ .endpoint = hop.endpoint, .auth = hop.auth, .strict_host_key_checking = hop.strict_host_key_checking };
    } else if (hop_index == hops.len) switch (spec) {
        .saved => |saved| blk: {
            owner = .{ .id = saved.connection_id, .revision = saved.config_revision };
            protocol = if (saved.protocol == .sftp) .sftp else .ssh;
            break :blk saved.immutable_config;
        },
        .temporary_ssh => |temporary| .{ .endpoint = temporary.structured_endpoint, .auth = temporary.auth_options, .strict_host_key_checking = temporary.strict_host_key_checking },
        .local, .plugin => return null,
    } else return null;
    return .{
        .connection_id = if (owner) |value| value.id else @fromBackingInt(0),
        .revision = if (owner) |value| value.revision else 1,
        .protocol = protocol,
        .name = if (name.len == 0) remote.endpoint.host else name,
        .host = remote.endpoint.host,
        .port = remote.endpoint.port,
        .user = remote.endpoint.user,
        .strict_host_key_checking = remote.strict_host_key_checking,
        .auth_mode = switch (remote.auth) {
            .agent => .agent,
            .private_key => .private_key,
            else => .password,
        },
        .identity_file = switch (remote.auth) {
            .private_key => |key| key.path,
            else => null,
        },
    };
}
