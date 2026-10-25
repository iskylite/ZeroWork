//! Window adapter for the public plugin facades. Only this host retains the
//! native App. Controller contexts carry owner IDs and restricted interfaces.
const std = @import("std");
const ui = @import("ui");
const application = @import("application_host.zig");
const identity = @import("../host/identity.zig");
const contexts = @import("../host/host_context.zig");
const operations = @import("../host/operation_store.zig");
const challenges = @import("../host/challenge_host.zig");
const content = @import("../host/content_context.zig");
const frame = @import("../host/frame_texture_sink.zig");
const contents = @import("plugin_content_host.zig");
const notify = @import("../host/notification_host.zig");
const presenter = @import("notification_presenter.zig");
const challenge_presenter = @import("plugin_challenge_presenter.zig");
const resolver = @import("../host/connection_config_resolver.zig");
const transports = @import("../host/transport_factory.zig");
const ssh = @import("../proto/ssh/session.zig");
const trust = @import("../proto/ssh/host_key_store.zig");
const operation = @import("../host/operation.zig");
const Entry = struct { owner: identity.SessionHandle, cancel: std.atomic.Value(bool) = .init(false), ended: bool = false, released: bool = false, donor: *Retainer };
var windows: [32]?*Host = @splat(null);
pub const TransferReceipt = struct {
    session: u64,
    generation: u64,
    operation: u64,
    attempt: ?u64,
    source: u64,
    destination: u64,
    old_context_instance: u64,
    new_context_instance: u64,
    old_lease_rejected: bool,
    source_input_closed: bool,
    source_frame_closed: bool,
    old_texture: ?u32,
    new_texture: ?u32,
    new_frame_revision: u64,
};
pub var transfer_receipts: [64]TransferReceipt = undefined;
pub var transfer_receipt_count: usize = 0;

pub const Host = struct {
    cx: *ui.Cx,
    application: *application.ApplicationHost,
    content_host: *contents.Host = undefined,
    notification_host: ?*notify.Host,
    notification_window: ?notify.WindowId,
    notification_presenter: ?*presenter.Presenter = null,
    challenge_presenter: ?*challenge_presenter.Presenter = null,
    retainer: ?*Retainer = null,
    challenge_host: *challenges.Host = undefined,
    pending_transfers: std.ArrayList(struct { owner: identity.SessionHandle, destination: identity.WindowId }) = .empty,
    native_context: *anyopaque = undefined,
    native_fullscreen: *const fn (*anyopaque, bool) anyerror!void = undefined,
    native_fullscreen_state: *const fn (*anyopaque) bool = undefined,
    entries: std.ArrayList(*Entry) = .empty,
    last_error: ?anyerror = null,
    shutdown_prepared: bool = false,
    closed: bool = false,
    /// Call after App.mount, once the primary/application window is ready.
    /// The generic App type is bound only here, never part of HostContext.
    pub fn mount(app: anytype, app_host: *application.ApplicationHost, notification_host: ?*notify.Host, notification_window: ?notify.WindowId) !*Host {
        const cx: *ui.Cx = app.cx;
        for (windows) |window| if (window) |existing| if (existing.cx == cx) return existing;
        var slot: ?usize = null;
        for (windows, 0..) |window, i| if (window == null) {
            slot = i;
            break;
        };
        const index = slot orelse return error.PluginWindowLimit;
        const self = try cx.bindState(Host, .{ .cx = cx, .application = app_host, .notification_host = notification_host, .notification_window = notification_window });
        const Native = @typeInfo(@TypeOf(app)).pointer.child;
        const Adapter = struct {
            fn request(raw: *anyopaque, enabled: bool) !void {
                const native: *Native = @ptrCast(@alignCast(raw));
                try native.setFullscreen(enabled);
            }
            fn state(raw: *anyopaque) bool {
                const native: *Native = @ptrCast(@alignCast(raw));
                return native.chromeState().fullscreen;
            }
        };
        const store = app.sharedImageStore() orelse return error.SharedImageStoreUnavailable;
        self.native_context = app;
        self.native_fullscreen = Adapter.request;
        self.native_fullscreen_state = Adapter.state;
        self.content_host = try contents.Host.init(cx, app_host.window_id, .{ .context = self, .request_fullscreen = requestFullscreen, .fullscreen_state = fullscreenState, .transfer = enqueueTransfer, .destinations = destinations }, frame.backendFor(store));
        app_host.workspace.content_services = self.content_host.factory();
        self.retainer = try Retainer.init();
        if (app_host.domain.tasks) |tasks| self.retainer.?.host_keys = try trust.HostKeyStore.load(cx.io, .cwd(), std.heap.c_allocator, tasks.authentication.options.known_hosts_path);
        if (notification_host) |host| {
            if (notification_window) |id| {
                self.notification_presenter = try presenter.Presenter.mount(cx, app_host.workspace.scope, host, id);
            }
        }
        const shared_challenges = try @import("challenge_window_host.zig").Services.mount(cx, app_host.workspace.scope);
        self.challenge_host = &shared_challenges.host;
        self.challenge_presenter = shared_challenges.view;
        const root_scope = cx.root_scope orelse return error.PluginRootScopeUnavailable;
        try root_scope.onCleanup(Host, self, prepareWindowShutdown);
        windows[index] = self;
        try cx.addAfterLayoutHook(self, afterLayout);
        installDomain(app_host.domain);
        return self;
    }
    pub fn installDomain(domain: *application.Domain) void {
        domain.sessions.setContextFactory(.{ .context = domain, .create = contextFor });
    }
    /// Invoke before native windows/Cx teardown on ordinary or exceptional
    /// process exit. Only owners using this domain's contexts are affected.
    pub fn prepareShutdown(domain: *application.Domain) void {
        for (windows) |window| if (window) |self| if (self.application.domain == domain) self.prepareWindowShutdown();
    }
    fn prepareWindowShutdown(self: *Host) void {
        if (self.shutdown_prepared or self.closed) return;
        self.shutdown_prepared = true;
        for (self.entries.items) |entry| {
            entry.cancel.store(true, .release);
            for (self.content_host.entries.items) |content_entry| if (content_entry.input.owner.eql(entry.owner)) content_entry.input.close();
            self.challenge_host.ownerClosed(entry.owner);
        }
        for (self.entries.items) |entry| {
            var receipt = self.application.sessions.shutdownOwner(entry.owner) catch unreachable;
            // Awaiting is a live controller, never a resource-retention receipt.
            // Keep the Cx/facades alive while that original factory joins. An
            // unknown native outcome is returned only after local shutdown.
            while (receipt == .awaiting) {
                _ = self.application.sessions.pollControllers() catch |err| failed: {
                    self.last_error = err;
                    std.log.err("plugin controller shutdown polling: {s}", .{@errorName(err)});
                    break :failed false;
                };
                const duration: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
                _ = std.c.nanosleep(&duration, null);
                receipt = self.application.sessions.shutdownOwner(entry.owner) catch unreachable;
            }
            self.application.domain.operation_history.ownerClosed(entry.owner) catch |err| {
                self.last_error = err;
            };
            if (receipt != .released) std.log.warn("plugin owner native cleanup remains {s} after controller shutdown", .{@tagName(receipt)});
            if (self.notification_host) |host| host.ownerEnded(.{ .session = entry.owner });
        }
    }
    pub fn deinit(self: *Host) void {
        if (self.closed) return;
        self.closed = true;
        self.cx.removeAfterLayoutHook(self);
        for (&windows) |*slot| if (slot.* == self) {
            slot.* = null;
        };
        // SessionHost shutdown joins controller/IO workers before Cx teardown.
        for (self.entries.items) |entry| {
            entry.cancel.store(true, .release);
            if (self.notification_host) |host| host.ownerEnded(.{ .session = entry.owner });
        }
        for (self.entries.items) |entry| if (entry.donor != self.retainer.?) {
            std.debug.assert(entry.donor.foreign_owners > 0);
            entry.donor.foreign_owners -= 1;
        };
        self.entries.deinit(self.cx.allocator);
        self.pending_transfers.deinit(self.cx.allocator);
        if (self.retainer) |retainer| retainer.finishOrRetain();
        self.retainer = null;
        sweepOrphans();
    }
    /// Called by the host after current capability/approval validation, never
    /// by a renderer. Changing policy revision revokes existing input leases.
    pub fn authorizeInput(app_host: *application.ApplicationHost, owner: identity.SessionHandle, allowed: bool, policy_revision: u64) !void {
        for (windows) |window| if (window) |self| if (self.application == app_host) {
            if (self.closed or self.shutdown_prepared or self.application.sessions.queryState(owner) == null) return error.StaleHostContext;
            try self.content_host.authorize(owner, allowed, policy_revision);
            return;
        };
        return error.PluginWindowUnavailable;
    }
    /// Built-in content receives the same restricted feedback route as plugins.
    pub fn publishFeedback(cx: *ui.Cx, owner: identity.SessionHandle, summary: []const u8) !void {
        for (windows) |window| if (window) |self| if (self.cx == cx) {
            if (self.closed or self.shutdown_prepared or self.application.sessions.queryState(owner) == null) return error.StaleHostContext;
            const host = self.notification_host orelse return error.NotificationHostUnavailable;
            const window_id = self.notification_window orelse return error.NotificationWindowUnavailable;
            try host.publishFeedback(window_id, .{ .session = owner }, summary);
            self.cx.requestRedraw();
            return;
        };
        return error.PluginWindowUnavailable;
    }
    fn contextFor(raw: *anyopaque, owner: identity.SessionHandle, key: operation.OperationKey, target: contexts.Target) !contexts.HostContext {
        const domain: *application.Domain = @ptrCast(@alignCast(raw));
        for (windows) |maybe| if (maybe) |window| if (window.application.domain == domain and window.application.window_id == target.window_id) return window.createContext(owner, key, target);
        // Initial built-in Local may start while its native window mounts.
        // It needs no remote capabilities. External interaction occurs only
        // after window registration, when the complete context is available.
        return .{ .owner = owner, .operation = key, .target = target };
    }
    fn createContext(self: *Host, owner: identity.SessionHandle, key: operation.OperationKey, target: contexts.Target) !contexts.HostContext {
        if (self.closed or self.shutdown_prepared) return error.PluginWindowClosed;
        var current: ?*Entry = null;
        for (self.entries.items) |entry| if (entry.owner.eql(owner)) {
            current = entry;
            break;
        };
        if (current == null) {
            if (self.entries.items.len >= 128 or self.retainer.?.token_count == self.retainer.?.tokens.len) return error.PluginOwnerLimit;
            const entry = try std.heap.c_allocator.create(Entry);
            errdefer std.heap.c_allocator.destroy(entry);
            entry.* = .{ .owner = owner, .donor = self.retainer.? };
            try self.entries.append(self.cx.allocator, entry);
            self.retainer.?.tokens[self.retainer.?.token_count] = entry;
            self.retainer.?.token_count += 1;
            current = entry;
        }
        if (current.?.ended) return error.OwnerClosed;
        const services = try self.content_host.factory().create(self.content_host, owner);
        const credentials: transports.Credentials = .{ .context = self, .resolve = credential };
        var factory: transports.Factory = .{ .allocator = std.heap.c_allocator, .library = &self.retainer.?.library, .credentials = credentials, .operation_key = key, .failed_open_owner = self.retainer.?.facade() };
        if (self.retainer.?.host_keys) |*keys| factory.host_key_store = keys;
        var notification_facade: ?notify.Facade = null;
        if (self.notification_host) |host| if (self.notification_window) |window_id| {
            const notification_owner: notify.notifications.NotificationOwner = .{ .window_id = @backingInt(window_id), .content = .{ .session = owner } };
            // Transfer stages a new facade before committing the existing owner binding.
            const state = self.application.sessions.queryState(owner) orelse return error.StaleHostContext;
            if (state.target.window_id == self.application.window_id) try host.bindOwner(notification_owner);
            notification_facade = host.facade(notification_owner);
        };
        return .{ .owner = owner, .operation = key, .target = target, .connection_configs = resolver.Resolver.init(&self.application.workspace.registry), .transports = factory, .credentials = credentials, .trust = .{ .ssh_host_keys = if (self.retainer.?.host_keys) |*keys| keys else null }, .tasks = .{ .cancel = &current.?.cancel, .operations = &self.application.domain.operation_history }, .notifications = notification_facade, .challenges = self.challenge_host, .preferences = .{ .context = self, .plugin_id = (self.application.sessions.queryState(owner) orelse return error.StaleHostContext).protocol_id, .read_value = preference }, .presentation = .{ .input = services.content_context, .frame_sink = services.frame_sink } };
    }
    fn requestFullscreen(raw: *anyopaque, enabled: bool) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.closed or self.shutdown_prepared) return error.PluginWindowClosed;
        try self.native_fullscreen(self.native_context, enabled);
    }
    fn fullscreenState(raw: *anyopaque) bool {
        const self: *Host = @ptrCast(@alignCast(raw));
        return !self.closed and !self.shutdown_prepared and self.native_fullscreen_state(self.native_context);
    }
    fn destinations(raw: *anyopaque, _: identity.SessionHandle, output: []identity.WindowId) usize {
        const self: *Host = @ptrCast(@alignCast(raw));
        var count: usize = 0;
        for (windows) |maybe| if (maybe) |target| {
            if (target == self or target.closed or target.shutdown_prepared or target.application.domain != self.application.domain or target.application.windowClosePending()) continue;
            if (count == output.len) break;
            output[count] = target.application.window_id;
            count += 1;
        };
        return count;
    }
    fn destination(self: *Host, id: identity.WindowId) !*Host {
        for (windows) |maybe| if (maybe) |target| if (target.application.window_id == id and target.application.domain == self.application.domain) {
            if (target == self) return error.SameWindow;
            if (target.closed or target.shutdown_prepared or target.application.windowClosePending() or target.application.workspace.shutting_down) return error.WindowClosing;
            return target;
        };
        return error.PluginWindowUnavailable;
    }
    fn enqueueTransfer(raw: *anyopaque, owner: identity.SessionHandle, id: identity.WindowId) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.closed or self.shutdown_prepared or self.application.windowClosePending()) return error.WindowClosing;
        _ = try self.destination(id);
        if (self.application.domain.operation_history.hasPending(owner)) return error.OwnerOperationPending;
        const manifest = self.application.sessions.manifestFor(owner) orelse return error.UnknownSession;
        const renderer = self.application.sessions.registry.renderer(manifest.content_renderer) orelse return error.ContentRendererUnavailable;
        if (!renderer.supports_window_transfer) return error.WindowTransferUnsupported;
        if (self.pending_transfers.items.len >= 128) return error.TransferQueueFull;
        for (self.pending_transfers.items) |pending| if (pending.owner.eql(owner)) return error.WindowTransferPending;
        try self.pending_transfers.append(self.cx.allocator, .{ .owner = owner, .destination = id });
        self.cx.requestRedraw();
    }
    fn drainTransfers(self: *Host) void {
        while (self.pending_transfers.items.len != 0) {
            const request = self.pending_transfers.orderedRemove(0);
            self.transferNow(request.owner, request.destination) catch |err| {
                self.last_error = err;
                for (self.content_host.entries.items) |entry| if (!entry.retired and entry.input.owner.eql(request.owner)) {
                    entry.input.transfer_state = .{ .failed = err };
                };
            };
        }
    }
    fn transferNow(self: *Host, owner: identity.SessionHandle, id: identity.WindowId) !void {
        const target = try self.destination(id);
        if (self.application.domain.operation_history.hasPending(owner)) return error.OwnerOperationPending;
        const state = self.application.sessions.queryState(owner) orelse return error.UnknownSession;
        if (state.target.window_id != self.application.window_id or state.lifecycle != .attached) return error.ContentNotAttached;
        for (self.challenge_host.records.items) |record| if (record.view.owner.belongsTo(challenges.Owner.from(owner)) and record.view.state == .pending) return error.OwnerChallengePending;
        const entry = for (self.entries.items) |candidate| {
            if (candidate.owner.eql(owner)) break candidate;
        } else return error.StaleHostContext;
        if (entry.ended or entry.cancel.load(.acquire)) return error.OwnerClosed;
        for (target.entries.items) |candidate| if (candidate.owner.eql(owner)) return error.ContentAlreadyAttached;
        try target.entries.ensureUnusedCapacity(target.cx.allocator, 1);
        target.entries.appendAssumeCapacity(entry);
        errdefer {
            _ = target.entries.pop();
            target.content_host.release(owner) catch {};
        }
        const old_input = self.inputFor(owner) orelse return error.ContentContextUnavailable;
        const old_frames = for (self.content_host.entries.items) |item| {
            if (!item.retired and item.input.owner.eql(owner)) break &item.frames;
        } else unreachable;
        const old_texture = old_frames.texture;
        const context = try target.createContext(owner, state.create_operation, .{ .window_id = target.application.window_id, .workspace_id = target.application.workspace_id });
        try context.presentation.input.?.setAuthorization(old_input.authorized, old_input.authorization_revision);
        try self.application.transferPluginTo(target.application, owner, context);
        // Commit contains no fallible operations after the provider rebind.
        if (self.retainer.? != entry.donor) entry.donor.foreign_owners -= 1;
        if (target.retainer.? != entry.donor) entry.donor.foreign_owners += 1;
        for (self.entries.items, 0..) |candidate, index| if (candidate == entry) {
            _ = self.entries.orderedRemove(index);
            break;
        };
        for (self.content_host.entries.items) |old| if (!old.retired and old.input.owner.eql(owner)) {
            old.input.transfer_state = .{ .completed = id };
        };
        self.content_host.release(owner) catch unreachable;
        context.presentation.input.?.transfer_state = .{ .completed = id };
        var rejected = false;
        if (old_input.last_transfer_lease) |lease| {
            _ = old_input.route(lease, std.math.maxInt(u64), .release_all, false) catch |err| result: {
                rejected = err == error.StaleInputLease;
                break :result false;
            };
        }
        if (transfer_receipt_count == transfer_receipts.len) {
            std.mem.copyForwards(TransferReceipt, transfer_receipts[0 .. transfer_receipts.len - 1], transfer_receipts[1..]);
            transfer_receipt_count -= 1;
        }
        transfer_receipts[transfer_receipt_count] = .{
            .session = @backingInt(owner.session_id),
            .generation = owner.generation,
            .operation = state.create_operation.operation_id,
            .attempt = state.create_operation.attempt_id,
            .source = @backingInt(self.application.window_id),
            .destination = @backingInt(id),
            .old_context_instance = old_input.context_instance,
            .new_context_instance = context.presentation.input.?.context_instance,
            .old_lease_rejected = rejected,
            .source_input_closed = old_input.closed,
            .source_frame_closed = !old_frames.accepting.load(.acquire) and old_frames.texture == null,
            .old_texture = old_texture,
            .new_texture = context.presentation.frame_sink.?.texture,
            .new_frame_revision = context.presentation.frame_sink.?.revision,
        };
        transfer_receipt_count += 1;
        if (self.notification_host) |host| if (target.notification_window) |window_id| {
            host.revokeActions(.{ .session = owner });
            host.moveOwner(.{ .session = owner }, window_id);
        };
        self.challenge_host.retireOwner(owner);
        target.cx.requestRedraw();
    }
    pub fn forApplication(app_host: *application.ApplicationHost) ?*Host {
        for (windows) |maybe| if (maybe) |self| if (self.application == app_host and !self.closed) return self;
        return null;
    }
    pub fn inputFor(self: *Host, owner: identity.SessionHandle) ?*content.Context {
        for (self.content_host.entries.items) |entry| if (!entry.retired and entry.input.owner.eql(owner)) return &entry.input;
        return null;
    }
    pub fn framesFor(self: *Host, owner: identity.SessionHandle) ?*frame.Sink {
        for (self.content_host.entries.items) |entry| if (!entry.retired and entry.input.owner.eql(owner)) return &entry.frames;
        return null;
    }
    fn preference(raw: *anyopaque, plugin_id: []const u8, key: []const u8) ?[]const u8 {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.closed) return null;
        return self.application.workspace.app_config.pluginPreference(plugin_id, key);
    }
    fn credential(raw: *anyopaque, resource_owner: identity.ResourceOwner, asset_owner: identity.AssetOwner, allocator: std.mem.Allocator) !ssh.Auth {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.closed) return error.PluginWindowClosed;
        const owner = switch (resource_owner) {
            .session => |owner| owner,
            else => return error.CredentialOwnerDenied,
        };
        var allowed = false;
        for (self.entries.items) |entry| if (entry.owner.eql(owner) and !entry.cancel.load(.acquire)) {
            allowed = true;
            break;
        };
        if (!allowed) return error.CredentialOwnerDenied;
        // get() checks the asset revision. No active Session or password/token
        // from any other owner is queried, and no secret enters a snapshot.
        const saved = try self.application.workspace.registry.get(asset_owner);
        return switch (saved.auth_mode) {
            .agent => .agent,
            .password => if (saved.password) |password| .{ .password = try allocator.dupeSentinel(u8, password, 0) } else error.AuthenticationInteractionRequired,
            .private_key => .{ .private_key = .{ .path = try allocator.dupeSentinel(u8, saved.identity_file orelse return error.MissingIdentityFile, 0), .passphrase = if (saved.key_passphrase) |passphrase| try allocator.dupeSentinel(u8, passphrase, 0) else null } },
        };
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Host = @ptrCast(@alignCast(raw));
        const ns = @import("../platform/realtime.zig").monotonicNs();
        self.tick(@intCast(@max(0, ns) / std.time.ns_per_ms)) catch |err| {
            self.last_error = err;
        };
        return .done;
    }
    pub fn tick(self: *Host, now_ms: u64) !void {
        if (self.closed or self.shutdown_prepared) return;
        self.drainTransfers();
        if (self.notification_host) |host| if (self.notification_window) |window_id| {
            host.setWindowFocus(window_id, self.cx.window_active);
        };
        if (self.retainer) |retainer| retainer.sweep();
        sweepOrphans();
        const workspace = self.application.workspace;
        var active: ?identity.SessionHandle = null;
        var content_focused = false;
        if (workspace.active_tab) |index| if (index < workspace.tabs.items.len) {
            const tab = workspace.tabs.items[index];
            if (tab.content_owner == .session and !tab.closing) active = tab.content_owner.session;
            if (self.cx.focus_manager.getFocused()) |focused| content_focused = focused == tab.root or focused.isDescendantOf(tab.root);
        };
        // A top layer owns keyboard focus before content routing.
        if (self.cx.overlay_stack.topmost() != null) content_focused = false;
        try self.content_host.tick(self.cx.window_active, active, content_focused);
        if (self.cx.consume(@import("challenge_window_host.zig").Services)) |shared| shared.active_owner = active;
        for (self.entries.items) |entry| {
            const snapshot = self.application.sessions.queryState(entry.owner);
            const ended = if (snapshot) |state| switch (state.lifecycle) {
                .closing, .closed, .failed, .ended, .cleanup_unknown => true,
                else => false,
            } else true;
            if (ended and !entry.ended) {
                entry.cancel.store(true, .release);
                entry.ended = true;
                self.challenge_host.retireOwner(entry.owner);
                try self.application.domain.operation_history.ownerClosed(entry.owner);
                if (self.notification_host) |host| host.ownerEnded(.{ .session = entry.owner });
                for (self.content_host.entries.items) |content_entry| if (content_entry.input.owner.eql(entry.owner)) content_entry.input.close();
            }
            const released = if (snapshot) |state| state.lifecycle == .closed or (state.lifecycle == .failed and state.create_cleanup == .released) else true;
            if (released and !entry.released) {
                try self.content_host.release(entry.owner);
                entry.released = true;
            }
        }
        if (self.notification_presenter) |view| {
            var avoid: [32]ui.ComputedRect = undefined;
            var count: usize = 0;
            for (self.cx.overlay_stack.layers) |maybe| if (maybe) |layer| {
                if (count == avoid.len) break;
                if (layer.state == .exiting or layer.suspended) continue;
                if (layer.content_node) |node| {
                    avoid[count] = node.globalRect();
                    count += 1;
                }
            };
            // App-owned detail cards may be retained outside Zenit's overlay
            // stack (notably global/session transfer popovers). Their public
            // roots are the same ones used by native Harness and presentation.
            const app_root = self.cx.root orelse return;
            collectNotificationObstacles(self.cx, app_root, &avoid, &count);
            try view.update(now_ms, self.cx.window_active, if (active) |owner| .{ .session = owner } else null, .{ .content = app_root.globalRect(), .avoid = avoid[0..count] });
        }
    }
};
// Explicit host-owned floating surfaces only; ordinary workspace panels and
// notification descendants must never become their own avoidance obstacles.
fn collectNotificationObstacles(cx: *ui.Cx, node: *ui.Node, avoid: []ui.ComputedRect, count: *usize) void {
    if (node.isPaintSkipped() or count.* == avoid.len or cx.overlay_stack.isNodeInSuspendedLayer(node)) return;
    if (node.style.overflow_hidden) {
        const bounds = node.globalRect();
        if (bounds.w <= 0.1 or bounds.h <= 0.1) return;
    }
    if (node.meta.ownership.meta.test_id) |id| {
        const floating = [_][]const u8{ "ai.panel", "transfer.manager", "transfer.session", "transfer.confirmation", "transfer.conflict", "connection.details", "status.connection", "status.detail", "status.theme", "session.menu", "files.context.menu", "files.history.menu", "asset.action", "asset.group.dialog", "tabs.rename" };
        for (floating) |known| if (std.mem.eql(u8, id, known)) {
            const rect = node.globalRect();
            if (rect.w > 0 and rect.h > 0) {
                avoid[count.*] = rect;
                count.* += 1;
            }
            return;
        };
    }
    for (node.children.items) |child| collectNotificationObstacles(cx, child, avoid, count);
}
pub const WindowHost = Host;

// Independent process allocations preserve an incomplete native cleanup graph
// even when the originating Cx is destroyed. No UI pointer is retained here.
var orphans: [32]?*Retainer = @splat(null);
const Retainer = struct {
    library: ssh.Library,
    host_keys: ?trust.HostKeyStore = null,
    held: std.atomic.Value(bool) = .init(false),
    reserved: usize = 0,
    retained_count: usize = 0,
    retained: [128]?*transports.OwnedTransport = @splat(null),
    tokens: [128]?*Entry = @splat(null),
    token_count: usize = 0,
    foreign_owners: usize = 0,
    fn init() !*Retainer {
        sweepOrphans();
        var room = false;
        for (orphans) |slot| if (slot == null) {
            room = true;
            break;
        };
        if (!room) return error.PluginCleanupRetainerLimit;
        const self = try std.heap.c_allocator.create(Retainer);
        errdefer std.heap.c_allocator.destroy(self);
        self.* = .{ .library = try ssh.Library.init() };
        return self;
    }
    fn lock(self: *Retainer) void {
        while (self.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Retainer) void {
        self.held.store(false, .release);
    }
    fn facade(self: *Retainer) transports.FailedOpenOwner {
        return .{ .context = self, .reserve = reserve, .release = release, .adopt = adopt };
    }
    fn reserve(raw: *anyopaque) !void {
        const self: *Retainer = @ptrCast(@alignCast(raw));
        self.lock();
        defer self.unlock();
        if (self.reserved + self.retained_count >= self.retained.len) return error.PluginCleanupQueueFull;
        self.reserved += 1;
    }
    fn release(raw: *anyopaque) void {
        const self: *Retainer = @ptrCast(@alignCast(raw));
        self.lock();
        defer self.unlock();
        std.debug.assert(self.reserved > 0);
        self.reserved -= 1;
    }
    fn adopt(raw: *anyopaque, transport: *transports.OwnedTransport) void {
        const self: *Retainer = @ptrCast(@alignCast(raw));
        self.lock();
        defer self.unlock();
        std.debug.assert(self.reserved > 0);
        self.reserved -= 1;
        for (&self.retained) |*slot| if (slot.* == null) {
            slot.* = transport;
            self.retained_count += 1;
            return;
        };
        unreachable; // prepareOwned reserved this slot before acquiring anything.
    }
    fn sweep(self: *Retainer) void {
        self.lock();
        defer self.unlock();
        for (&self.retained) |*slot| if (slot.*) |transport| {
            if (transport.close() != .released) continue;
            transport.deinit() catch continue;
            slot.* = null;
            self.retained_count -= 1;
        };
    }
    fn empty(self: *Retainer) bool {
        self.lock();
        defer self.unlock();
        return self.foreign_owners == 0 and self.reserved == 0 and self.retained_count == 0;
    }
    fn destroy(self: *Retainer) void {
        for (self.tokens[0..self.token_count]) |token| if (token) |entry| std.heap.c_allocator.destroy(entry);
        if (self.host_keys) |*keys| keys.deinit();
        self.library.deinit();
        std.heap.c_allocator.destroy(self);
    }
    fn finishOrRetain(self: *Retainer) void {
        self.sweep();
        if (self.empty()) {
            self.destroy();
            return;
        }
        for (&orphans) |*slot| if (slot.* == null) {
            slot.* = self;
            if (self.foreign_owners == 0) std.log.warn("plugin native cleanup remains unknown; preserving its independent library and ownership graph", .{});
            return;
        };
        // A full orphan table is checked before a new window host is created.
        // Retain this allocation even in an invariant failure; never free a
        // library underneath an incomplete native cleanup graph.
        std.log.err("plugin cleanup retention table exhausted; native owner retained until process exit", .{});
    }
};
fn sweepOrphans() void {
    for (&orphans) |*slot| if (slot.*) |retainer| {
        retainer.sweep();
        if (retainer.empty()) {
            slot.* = null;
            retainer.destroy();
        }
    };
}

const TransferTestStore = struct {
    next: u32 = 0,
    releases: usize = 0,
    pub fn createStreamTexture(self: *@This(), _: u32, _: u32) !u32 {
        self.next += 1;
        return self.next;
    }
    pub fn updateStreamTexture(_: *@This(), _: u32, _: []const u8) !void {}
    pub fn unloadTexture(self: *@This(), _: u32) void {
        self.releases += 1;
    }
};
const TransferTestNative = struct {
    cx: *ui.Cx,
    store: *TransferTestStore,
    pub fn setFullscreen(_: *@This(), _: bool) !void {}
    pub fn chromeState(_: *@This()) struct { fullscreen: bool } {
        return .{ .fullscreen = false };
    }
    pub fn sharedImageStore(self: *@This()) ?*TransferTestStore {
        return self.store;
    }
};
const TransferTestWindow = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    workspace: *@import("workspace.zig").Workspace,
    app: *application.ApplicationHost,
    host: *Host,
    native: TransferTestNative,
    config: @import("../config/config.zig").Config = .{},
    tmp: @TypeOf(std.testing.tmpDir(.{})),
    path: [:0]const u8,
    alive: bool = true,
    fn init(self: *@This(), domain: *application.Domain, store: *TransferTestStore) !void {
        const a = std.testing.allocator;
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .workspace = undefined, .app = undefined, .host = undefined, .native = undefined, .tmp = std.testing.tmpDir(.{}), .path = undefined };
        self.cx.setViewport(1000, 700);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        var nodes: [4]*ui.Node = undefined;
        for (&nodes) |*node| {
            node.* = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 100 } }, .{});
            try self.cx.root.?.appendChild(a, node.*);
        }
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hosts.toml", .data = "" });
        self.path = try self.tmp.dir.realPathFileAlloc(std.testing.io, "hosts.toml", a);
        self.workspace = try @import("workspace.zig").Workspace.init(a, self.cx, self.scope, std.testing.io, &self.config, self.path, nodes[0], nodes[1], nodes[2], nodes[3]);
        self.app = try application.ApplicationHost.initInDomain(domain, self.workspace, null);
        try self.scope.onCleanup(application.ApplicationHost, self.app, application.ApplicationHost.deinit);
        self.app.install();
        self.native = .{ .cx = self.cx, .store = store };
        self.host = try Host.mount(&self.native, self.app, null, null);
    }
    fn deinit(self: *@This()) void {
        if (!self.alive) return;
        self.alive = false;
        self.host.prepareWindowShutdown();
        self.host.deinit();
        self.cx.clearFocus();
        self.scope.dispose();
        self.cx.deinit();
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
    fn open(self: *@This(), plugin: *@import("../plugins/fixture_probe/plugin.zig").Plugin, request: u64) !@import("../host/session_host.zig").Accepted {
        const accepted = try self.app.openEnvelope(.{ .protocol_id = "fixture_probe", .name = "Transfer canvas", .payload_version = 1, .payload = "{}" }, request);
        _ = try self.app.safeTick();
        const runtime = plugin.runtimeFor(accepted.handle).?;
        try self.host.challenge_host.submitAnswer(accepted.handle, runtime.challenge_id, accepted.handle.generation, .{ .secret_input = "controlled-test-only" }, runtime.challenge_deadline - 1);
        _ = try self.app.safeTick();
        _ = try self.app.safeTick();
        try std.testing.expectEqual(@import("../host/session_host.zig").Lifecycle.attached, self.app.sessions.queryState(accepted.handle).?.lifecycle);
        return accepted;
    }
};

test "fixture production content transfer remounts same owner and preserves donor until destination closes" {
    const fixture = @import("../plugins/fixture_probe/plugin.zig");
    const a = std.testing.allocator;
    const plugin = try fixture.Plugin.init(a);
    defer plugin.deinit();
    const domain = try application.Domain.initWithContributions(a, false, &.{plugin.manifest()}, &.{plugin.renderer()});
    defer domain.deinit();
    var store: TransferTestStore = .{};
    var first: TransferTestWindow = undefined;
    try first.init(domain, &store);
    defer first.deinit();
    var second: TransferTestWindow = undefined;
    try second.init(domain, &store);
    defer second.deinit();
    const accepted = try first.open(plugin, 1001);
    const sibling = try second.open(plugin, 1002);
    const source_sibling = try first.open(plugin, 1003);
    const input = first.host.inputFor(accepted.handle).?;
    const old_sink = first.host.framesFor(accepted.handle).?;
    const donor = first.host.retainer.?;
    const source_window = first.app.window_id;
    try input.setAuthorization(true, 7);
    input.setFocus(true, false);
    const lease = try input.acquire(.automation, 7);
    const old_texture = old_sink.texture.?;
    try input.transferWindow(second.app.window_id);
    try std.testing.expectEqual(@as(usize, 2), first.workspace.tabs.items.len);
    try first.host.tick(1);
    if (first.host.last_error) |err| {
        std.debug.print("transfer error {s}\n", .{@errorName(err)});
        return err;
    }
    const next_input = second.host.inputFor(accepted.handle).?;
    const next_sink = second.host.framesFor(accepted.handle).?;
    try std.testing.expect(input.closed and !old_sink.accepting.load(.acquire) and old_sink.texture == null);
    try std.testing.expect(old_texture != next_sink.texture.?);
    try std.testing.expectEqual(@as(usize, 1), first.workspace.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 2), second.workspace.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 3), plugin.creates);
    try std.testing.expectEqual(second.app, domain.ownerForHandle(accepted.handle).?);
    try std.testing.expect(domain.sessions.queryState(accepted.handle).?.create_operation.eql(accepted.operation));
    next_input.setFocus(true, false);
    const next_lease = try next_input.acquire(.automation, 7);
    try std.testing.expectEqual(lease.id, next_lease.id);
    try std.testing.expect(next_lease.context_instance != lease.context_instance);
    try std.testing.expectError(error.StaleInputLease, next_input.route(lease, 1, .{ .text = "stale" }, false));
    try std.testing.expectError(error.StaleInputLease, input.route(lease, 1, .{ .text = "stale" }, false));
    try std.testing.expectEqual(@as(usize, 1), donor.foreign_owners);
    first.deinit();
    try std.testing.expect(domain.ownerForWindow(source_window) == null);
    try std.testing.expectEqual(@as(usize, 1), plugin.releases);
    try std.testing.expectEqual(@import("../host/session_host.zig").Lifecycle.ended, domain.sessions.queryState(source_sibling.handle).?.lifecycle);
    try std.testing.expect(!plugin.runtimeFor(accepted.handle).?.context.?.tasks.?.cancelled());
    try std.testing.expect(try next_input.route(next_lease, 1, .{ .pointer = .{ .x = 12, .y = 8, .buttons = 0 } }, false));
    _ = try next_sink.drain();
    try std.testing.expectEqual(@as(usize, 1), plugin.runtimeFor(accepted.handle).?.input_events);
    try std.testing.expectEqual(@import("../host/session_host.zig").Lifecycle.attached, domain.sessions.queryState(sibling.handle).?.lifecycle);
    second.deinit();
    try std.testing.expectEqual(@as(usize, 3), plugin.releases);
    for (orphans) |orphan| try std.testing.expect(orphan != donor);
    try std.testing.expectEqual(@as(usize, store.next), store.releases);
}

test "fixture production content transfer returns with fresh facade and single donor token" {
    const fixture = @import("../plugins/fixture_probe/plugin.zig");
    const a = std.testing.allocator;
    const plugin = try fixture.Plugin.init(a);
    defer plugin.deinit();
    const domain = try application.Domain.initWithContributions(a, false, &.{plugin.manifest()}, &.{plugin.renderer()});
    defer domain.deinit();
    var store: TransferTestStore = .{};
    var first: TransferTestWindow = undefined;
    try first.init(domain, &store);
    defer first.deinit();
    var second: TransferTestWindow = undefined;
    try second.init(domain, &store);
    defer second.deinit();
    const accepted = try first.open(plugin, 1011);
    const original = first.host.inputFor(accepted.handle).?;
    try original.setAuthorization(true, 3);
    original.setFocus(true, false);
    const old = try original.acquire(.automation, 3);
    try original.transferWindow(second.app.window_id);
    try first.host.tick(1);
    const remote = second.host.inputFor(accepted.handle).?;
    remote.setFocus(true, false);
    const middle = try remote.acquire(.automation, 3);
    try remote.transferWindow(first.app.window_id);
    try second.host.tick(2);
    const returned = first.host.inputFor(accepted.handle).?;
    returned.setFocus(true, false);
    const fresh = try returned.acquire(.automation, 3);
    try std.testing.expect(fresh.context_instance != old.context_instance and fresh.context_instance != middle.context_instance);
    try std.testing.expectError(error.StaleInputLease, returned.route(old, 1, .release_all, false));
    try std.testing.expectError(error.StaleInputLease, returned.route(middle, 1, .release_all, false));
    try std.testing.expectEqual(@as(usize, 1), first.host.retainer.?.token_count);
    try std.testing.expectEqual(@as(usize, 0), first.host.retainer.?.foreign_owners);
    try std.testing.expectEqual(@as(usize, 0), second.host.retainer.?.token_count);
    try std.testing.expectEqual(@as(usize, 1), plugin.creates);
    try std.testing.expectEqual(first.app, domain.ownerForHandle(accepted.handle).?);
    second.deinit();
    try std.testing.expect(!plugin.runtimeFor(accepted.handle).?.context.?.tasks.?.cancelled());
    try std.testing.expect(try returned.route(fresh, 1, .{ .text = "after return" }, false));
    first.deinit();
    try std.testing.expectEqual(@as(usize, 1), plugin.releases);
    try std.testing.expectEqual(@as(usize, store.next), store.releases);
}

test "fixture production content transfer rolls back target mount on provider refusal" {
    const fixture = @import("../plugins/fixture_probe/plugin.zig");
    const a = std.testing.allocator;
    const plugin = try fixture.Plugin.init(a);
    defer plugin.deinit();
    var manifest = plugin.manifest();
    var vtable = manifest.session_factory.?.vtable.*;
    vtable.rebind_context = struct {
        fn reject(_: *anyopaque, _: identity.SessionHandle, _: contexts.HostContext) !void {
            return error.RebindRejected;
        }
    }.reject;
    manifest.session_factory.?.vtable = &vtable;
    const domain = try application.Domain.initWithContributions(a, false, &.{manifest}, &.{plugin.renderer()});
    defer domain.deinit();
    var store: TransferTestStore = .{};
    var first: TransferTestWindow = undefined;
    try first.init(domain, &store);
    defer first.deinit();
    var second: TransferTestWindow = undefined;
    try second.init(domain, &store);
    defer second.deinit();
    const accepted = try first.open(plugin, 1021);
    const original = first.host.inputFor(accepted.handle).?;
    const original_sink = first.host.framesFor(accepted.handle).?;
    const original_texture = original_sink.texture;
    const original_attachment = domain.sessions.queryState(accepted.handle).?.attachment.?;
    try original.setAuthorization(true, 2);
    original.setFocus(true, false);
    const revoked = try original.acquire(.automation, 2);
    try original.transferWindow(second.app.window_id);
    try first.host.tick(1);
    try std.testing.expectEqual(error.RebindRejected, first.host.last_error.?);
    try std.testing.expectEqualStrings("RebindRejected", @errorName(original.transfer_state.failed));
    try std.testing.expectEqual(@as(usize, 1), first.workspace.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), second.workspace.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), second.host.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), first.host.retainer.?.foreign_owners);
    try std.testing.expect(std.meta.eql(original_attachment, domain.sessions.queryState(accepted.handle).?.attachment.?));
    try std.testing.expect(!original.closed and original_sink.texture == original_texture and original_sink.accepting.load(.acquire));
    try std.testing.expect(plugin.runtimeFor(accepted.handle).?.input == original);
    try std.testing.expect(plugin.runtimeFor(accepted.handle).?.frame_sink == original_sink);
    original.setFocus(true, false);
    const fresh = try original.acquire(.automation, 2);
    try std.testing.expectError(error.StaleInputLease, original.route(revoked, 1, .release_all, false));
    try std.testing.expect(try original.route(fresh, 1, .{ .text = "rollback survived" }, false));
    second.deinit();
    try std.testing.expectEqual(@as(usize, 0), plugin.releases);
    first.deinit();
    try std.testing.expectEqual(@as(usize, 1), plugin.releases);
    try std.testing.expectEqual(@as(usize, store.next), store.releases);
}

test "fixture generic new window freezes its envelope and tracks target renderer once" {
    const fixture = @import("../plugins/fixture_probe/plugin.zig");
    const a = std.testing.allocator;
    const plugin = try fixture.Plugin.init(a);
    defer plugin.deinit();
    const domain = try application.Domain.initWithContributions(a, false, &.{plugin.manifest()}, &.{plugin.renderer()});
    defer domain.deinit();
    var store: TransferTestStore = .{};
    var first: TransferTestWindow = undefined;
    try first.init(domain, &store);
    defer first.deinit();
    var second: TransferTestWindow = undefined;
    try second.init(domain, &store);
    defer second.deinit();
    const asset = try first.workspace.registry.add(.{ .name = "Frozen canvas", .host = "", .user = "", .protocol_id = "fixture_probe", .plugin_payload = "{\"show_grid\":false}" });
    try first.workspace.identities.appendHosts(a, first.workspace.registry.hosts.len);
    var frozen = try first.app.freezeWindowConnection(first.workspace.hostId(0).?);
    defer frozen.deinit();
    try std.testing.expect(frozen.remote == null);
    var edited = first.workspace.registry.hosts[0];
    edited.name = "Edited after click";
    edited.plugin_payload = "{\"show_grid\":true}";
    _ = try first.workspace.registry.update(asset, edited);
    const accepted = try second.app.createWindowConnection(&frozen);
    try std.testing.expectEqual(@as(usize, 1), plugin.creates);
    try std.testing.expectEqual(@as(usize, 1), second.app.plugin_attempts.items.len);
    try std.testing.expectEqual(@as(usize, 0), first.app.plugin_attempts.items.len);
    const retained = domain.sessions.connectionEnvelope(accepted.handle).?;
    try std.testing.expectEqual(asset.id, retained.id);
    try std.testing.expectEqual(asset.revision, retained.revision);
    try std.testing.expectEqualStrings("Frozen canvas", retained.name);
    try std.testing.expectEqualStrings("{\"show_grid\":false}", retained.payload);
    try std.testing.expectEqual(second.app.window_id, domain.sessions.queryState(accepted.handle).?.target.window_id);
    _ = try second.app.safeTick();
    const runtime = plugin.runtimeFor(accepted.handle).?;
    try second.host.challenge_host.submitAnswer(accepted.handle, runtime.challenge_id, accepted.handle.generation, .{ .secret_input = "controlled-test-only" }, runtime.challenge_deadline - 1);
    _ = try second.app.safeTick();
    _ = try second.app.safeTick();
    try std.testing.expectEqual(@as(usize, 1), second.workspace.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), first.workspace.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), plugin.creates);
    try std.testing.expect(!runtime.show_grid);
    try std.testing.expectEqual(@import("../host/session_host.zig").Lifecycle.attached, domain.sessions.queryState(accepted.handle).?.lifecycle);
}
