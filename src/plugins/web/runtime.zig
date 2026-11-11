//! A session-owned WebKit view and optional authenticated SSH proxy. The
//! application thread owns state and browser calls. The proxy owns its workers.
const std = @import("std");
const identity = @import("../../host/identity.zig");
const sessions = @import("../../host/session_host.zig");
const context_api = @import("../../host/host_context.zig");
const resolver = @import("../../host/connection_config_resolver.zig");
const proxy_api = @import("../../host/web_proxy.zig");
const web = @import("../../host/web_surface.zig");
const wakeup = @import("../../platform/presentation_wakeup.zig");
const config = @import("config.zig");
const bookmarks = @import("bookmarks.zig");
const navigation = @import("navigation.zig");
const page_api = @import("page_service.zig");
const ssh_challenges = @import("ssh_challenges.zig");
const ssh_auth = @import("../../proto/ssh/auth_challenge.zig");
const page_requests = @import("request_bridge.zig");

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    owner_thread: std.Thread.Id,
    owner: identity.SessionHandle,
    operation: sessions.OperationKey,
    context: ?context_api.HostContext,
    temporary: bool,
    url_mode: config.UrlMode,
    controller: navigation.Controller,
    route: ?resolver.FrozenRoute = null,
    bookmark_arena: std.heap.ArenaAllocator,
    bookmark_items: []const bookmarks.Bookmark = &.{},

    proxy: ?*proxy_api.Proxy = null,
    ssh_prompts: ?*ssh_challenges.Bridge = null,
    ssh_prompt_ids: ssh_auth.RequestCounter = .{},
    proxy_attempt: ?navigation.RouteAttempt = null,
    proxy_stopping: bool = false,
    surface: ?web.Surface = null,
    page_prompts: ?page_requests.Bridge = null,
    surface_state: ?web.Snapshot = null,
    native_mount: ?web.Mount = null,
    presentation: ?u64 = null,
    next_presentation: u64 = 1,
    native_navigation_id: u64 = 0,
    awaiting_navigation: bool = false,
    path_error: ?[]const u8 = null,
    page_error: ?[]const u8 = null,
    published: bool = false,
    stopping: bool = false,
    close_operation: ?sessions.OperationKey = null,
    create_report: ?sessions.CloseReceipt = null,
    close_report: ?sessions.CloseReceipt = null,

    pub fn init(a: std.mem.Allocator, request: sessions.CreateRequest, payload: config.Payload) !*Runtime {
        if (request.key.owner != .session or !request.key.owner.session.eql(request.handle)) return error.InvalidOperationOwner;
        if (request.context) |ctx| {
            try ctx.requireOwner(request.handle);
            if (!ctx.operation.eql(request.key)) return error.StaleHostContext;
        }
        const self = try a.create(Runtime);
        errdefer a.destroy(self);
        self.* = .{
            .allocator = a,
            .owner_thread = std.Thread.getCurrentId(),
            .owner = request.handle,
            .operation = request.key,
            .context = request.context,
            .temporary = @backingInt(request.spec.plugin.id) == 0,
            .url_mode = payload.url_mode,
            .controller = try navigation.Controller.init(a, request.handle, payload.route.mode, payload.start_url),
            .bookmark_arena = .init(a),
        };
        errdefer self.controller.deinit();
        errdefer self.bookmark_arena.deinit();
        self.bookmark_items = try copyBookmarks(self.bookmark_arena.allocator(), payload.bookmarks);
        if (payload.route.mode == .ssh) {
            const ctx = request.context orelse return error.HostContextUnavailable;
            const configs = ctx.connection_configs orelse return error.ConfigurationResolverUnavailable;
            if (ctx.transports == null) return error.TransportFactoryUnavailable;
            var ids: [config.max_hops]identity.ConnectionId = undefined;
            for (payload.route.hop_asset_ids, 0..) |id, index| ids[index] = @fromBackingInt(id);
            self.route = try configs.freezeRoute(ids[0..payload.route.hop_asset_ids.len], a);
        }
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        std.debug.assert(self.stopping and self.proxy == null and self.surface == null);
        self.controller.deinit();
        if (self.route) |*route| route.deinit();
        self.bookmark_arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn poll(self: *Runtime) !bool {
        if (self.stopping) {
            const pending = self.proxy != null;
            _ = self.cleanupProxy();
            return pending and self.proxy == null;
        }
        var changed = self.pollProxy();
        if (!self.proxy_stopping and self.controller.path == .connecting) {
            if (self.ssh_prompts) |prompts| {
                changed = (prompts.poll() catch |err| failed: {
                    const attempt = self.proxy_attempt.?;
                    self.disconnect(attempt, if (err == error.Cancelled) "已取消 SSH 连接。" else "无法完成 SSH 认证提示。");
                    self.destroySurface();
                    break :failed true;
                }) or changed;
            }
        }
        if (self.surface) |*surface| changed = (try self.pollSurface(surface)) or changed;
        if (self.controller.path == .idle and self.proxy != null) return changed;
        if (self.controller.route == .direct and self.surface == null and self.controller.content_slot_attached and self.controller.pending_url != null) {
            self.openSurface(null) catch |err| {
                self.controller.failPendingLoad();
                self.page_error = surfaceError(err);
                return true;
            };
            _ = self.controller.markViewReady(self.controller.view());
            changed = true;
        }
        if (try self.controller.nextWork()) |work| {
            switch (work) {
                .connect => |attempt| self.startProxy(attempt) catch |err| {
                    self.path_error = proxyError(err);
                    _ = self.controller.routeFailed(attempt);
                },
                .open_get => |request| {
                    self.awaiting_navigation = true;
                    self.page_error = null;
                    self.surface.?.navigate(request.url) catch |err| {
                        self.awaiting_navigation = false;
                        _ = self.controller.didFail(request.navigation);
                        self.page_error = surfaceError(err);
                    };
                },
            }
            return true;
        }
        return changed;
    }

    pub fn close(self: *Runtime) sessions.CloseReceipt {
        if (!self.stopping) {
            self.stopping = true;
            self.controller.close();
            self.presentation = null;
            self.requestProxyStop();
            self.destroySurface();
        }
        return self.cleanupProxy();
    }

    pub fn closeReceipt(self: *const Runtime) sessions.CloseReceipt {
        const proxy = self.proxy orelse return .released;
        const state = proxy.snapshot();
        return if (state.cleanup == .unknown) .unknown else .awaiting;
    }

    fn startProxy(self: *Runtime, attempt: navigation.RouteAttempt) !void {
        std.debug.assert(self.proxy == null);
        if (!web.supportsProxy()) return error.WebProxyUnavailable;
        const ctx = self.context orelse return error.HostContextUnavailable;
        var factory = ctx.transports orelse return error.TransportFactoryUnavailable;
        if (@import("zenit_app").test_harness.enabled) {
            factory.acceptance_hold_native_cleanup = &proxy_api.acceptance_hold_native_cleanup;
        }
        if (ctx.challenges) |host| {
            const prompts = try self.allocator.create(ssh_challenges.Bridge);
            prompts.* = ssh_challenges.Bridge.init(self.owner, self.operation, host, &self.ssh_prompt_ids);
            self.ssh_prompts = prompts;
            prompts.configure(&factory);
        }
        errdefer self.destroyPrompts();
        const proxy = try proxy_api.Proxy.prepare(factory, self.owner, self.operation, &self.route.?);
        errdefer proxy.deinit() catch unreachable;
        if (@import("zenit_app").test_harness.enabled) proxy.observeAcceptanceWorkers();
        try proxy.start();
        self.proxy = proxy;
        self.proxy_attempt = attempt;
        self.proxy_stopping = false;
        self.path_error = null;
    }

    fn pollProxy(self: *Runtime) bool {
        const proxy = self.proxy orelse return false;
        if (self.proxy_stopping) {
            _ = self.cleanupProxy();
            return self.proxy == null;
        }
        const state = proxy.snapshot();
        const attempt = self.proxy_attempt.?;
        switch (state.phase) {
            .prepared, .connecting => return false,
            .ready => {
                if (self.surface != null) return false;
                var endpoint = proxy.endpoint(self.owner, self.operation) orelse return false;
                defer std.crypto.secureZero(u8, &endpoint.credentials.username);
                defer std.crypto.secureZero(u8, &endpoint.credentials.password);
                self.openSurface(&endpoint) catch |err| {
                    self.disconnect(attempt, surfaceError(err));
                    self.destroySurface();
                };
                return true;
            },
            .closing, .failed, .closed => {
                self.disconnect(attempt, if (state.failure) |err| proxyError(err) else "SSH 转发已断开。");
                _ = self.cleanupProxy();
                return true;
            },
        }
    }

    fn requestProxyStop(self: *Runtime) void {
        if (self.proxy) |proxy| {
            proxy.requestStop();
            self.proxy_stopping = true;
        }
        if (self.ssh_prompts) |prompts| prompts.cancel();
    }

    fn cleanupProxy(self: *Runtime) sessions.CloseReceipt {
        const proxy = self.proxy orelse return .released;
        const state = proxy.snapshot();
        switch (state.cleanup) {
            .released => {
                proxy.deinit() catch return .awaiting;
                self.proxy = null;
                self.destroyPrompts();
                self.proxy_attempt = null;
                self.proxy_stopping = false;
                return .released;
            },
            .awaiting => return .awaiting,
            .unknown => {
                if (state.phase == .closed or state.phase == .failed) proxy.retryCleanup() catch {};
                return .unknown;
            },
        }
    }

    fn destroyPrompts(self: *Runtime) void {
        if (self.ssh_prompts) |prompts| {
            prompts.cancel();
            self.allocator.destroy(prompts);
            self.ssh_prompts = null;
        }
    }

    fn disconnect(self: *Runtime, attempt: navigation.RouteAttempt, message: []const u8) void {
        self.path_error = message;
        if (self.controller.path == .ready) {
            if (self.surface) |*surface| _ = self.pollSurface(surface) catch false;
        }
        if (!self.controller.routeFailed(attempt)) _ = self.controller.routeDisconnected(attempt);
        self.cancelPagePrompts();
        self.unbindSurface();
        if (self.surface) |*surface| surface.stop() catch {};
        self.requestProxyStop();
    }

    fn openSurface(self: *Runtime, endpoint: ?*const proxy_api.Endpoint) !void {
        std.debug.assert(self.surface == null);
        var surface = if (endpoint) |remote|
            try web.Surface.initProxied(self.owner, remote.port, &remote.credentials.username, &remote.credentials.password)
        else
            try web.Surface.init(self.owner);
        errdefer surface.deinit();
        try surface.setChangeCallback(nativeChanged);
        self.surface = surface;
        if (self.context) |ctx| if (ctx.challenges) |host| {
            self.page_prompts = page_requests.Bridge.init(self.owner, host, &self.ssh_prompt_ids);
        };
    }

    fn destroySurface(self: *Runtime) void {
        self.cancelPagePrompts();
        self.page_prompts = null;
        self.unbindSurface();
        if (self.surface) |*surface| surface.deinit();
        self.surface = null;
        self.surface_state = null;
        self.native_navigation_id = 0;
        self.awaiting_navigation = false;
    }

    fn cancelPagePrompts(self: *Runtime) void {
        if (self.page_prompts) |*prompts| if (self.surface) |*surface| prompts.cancel(surface);
    }

    fn unbindSurface(self: *Runtime) void {
        if (self.native_mount) |binding| if (self.surface) |*surface| surface.unbind(binding) catch {};
        self.native_mount = null;
    }

    fn pollSurface(self: *Runtime, surface: *web.Surface) !bool {
        if (self.controller.path == .disconnected) return false;
        const state = try surface.snapshot();
        const location_changed = if (self.surface_state) |previous| previous.url_revision != state.url_revision else false;
        var changed = !std.meta.eql(self.surface_state, @as(?web.Snapshot, state));
        if (self.page_prompts) |*prompts| {
            changed = (try prompts.poll(surface)) or changed;
        } else if (try surface.copyRequest()) |incoming| {
            var request = incoming;
            defer request.deinit();
            _ = try surface.replyRequest(request.token, false, "", "");
            self.page_error = "无法显示网页交互请求。";
            changed = true;
        }
        self.surface_state = state;
        if (self.controller.path == .connecting and self.proxy_attempt != null) {
            const attempt = self.proxy_attempt.?;
            if (!state.ready) return changed;
            _ = self.controller.routeReady(attempt);
            _ = self.controller.markViewReady(attempt.view);
            changed = true;
        }
        if (!self.controller.view_ready) return changed;
        if (state.navigation_id != 0 and state.navigation_id != self.native_navigation_id) {
            self.native_navigation_id = state.navigation_id;
            if (!self.awaiting_navigation) _ = try self.controller.beginSiteNavigation(self.controller.view());
            self.awaiting_navigation = false;
            self.page_error = null;
            changed = true;
        }
        if (self.awaiting_navigation) return changed;
        if (self.controller.navigation) |request| {
            if (state.committed and !self.controller.navigation_committed) {
                if (try surface.copyUrl(self.allocator)) |url| {
                    defer self.allocator.free(url);
                    changed = (self.controller.didCommit(request, url, if (state.committed_get) .get else .other_or_unknown) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => failed: {
                            self.page_error = "网页返回的地址不可用。";
                            try surface.stop();
                            break :failed self.controller.didFail(request);
                        },
                    }) or changed;
                }
            }
            if (state.failed) {
                changed = self.controller.didFail(request) or changed;
            } else if (state.displayed and !state.loading) {
                changed = self.controller.didFinish(request) or changed;
            }
        } else if (location_changed and state.displayed and state.committed and !state.loading and !state.failed) {
            if (try surface.copyUrl(self.allocator)) |url| {
                defer self.allocator.free(url);
                changed = (self.controller.observeDisplayedUrl(url) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => false,
                }) or changed;
            }
        }
        if (state.failed and self.controller.page != .failed) {
            self.controller.page = .failed;
            changed = true;
        }
        return changed;
    }

    const vtable: page_api.VTable = .{
        .snapshot = snapshot,
        .attach = attach,
        .surface_binding = surfaceBinding,
        .detach = detach,
        .release_focus = releaseFocus,
        .command = command,
        .mutate_bookmark = mutateBookmark,
    };
    pub fn pageVTable() *const page_api.VTable {
        return &vtable;
    }

    fn active(raw: *anyopaque, owner: identity.SessionHandle) !*Runtime {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        if (std.Thread.getCurrentId() != self.owner_thread) return error.WebRuntimeOffMainThread;
        if (!self.owner.eql(owner) or self.stopping) return error.StaleWebOwner;
        return self;
    }

    fn attach(raw: *anyopaque, owner: identity.SessionHandle) !u64 {
        const self = try active(raw, owner);
        if (self.presentation != null) return error.WebPageAlreadyAttached;
        const token = self.next_presentation;
        self.next_presentation = try identity.advance(token);
        self.presentation = token;
        self.controller.setContentSlotAttached(true);
        wakeup.notify();
        return token;
    }

    fn surfaceBinding(raw: *anyopaque, owner: identity.SessionHandle, token: u64) !?page_api.SurfaceBinding {
        const self = try active(raw, owner);
        if (self.presentation != token) return error.StaleWebSurfaceMount;
        if (!self.controller.view_ready or self.controller.path != .ready) return null;
        const surface = if (self.surface) |*value| value else return null;
        return .{ .surface = surface, .binding = &self.native_mount };
    }

    fn detach(raw: *anyopaque, owner: identity.SessionHandle, token: u64) void {
        const self = active(raw, owner) catch return;
        if (self.presentation != token) return;
        self.unbindSurface();
        self.presentation = null;
        self.controller.setContentSlotAttached(false);
    }

    fn releaseFocus(raw: *anyopaque, owner: identity.SessionHandle, token: u64) !void {
        const pair = (try surfaceBinding(raw, owner, token)) orelse return;
        if (pair.binding.*) |mount| try pair.surface.releaseFocus(mount);
    }

    fn command(raw: *anyopaque, owner: identity.SessionHandle, value: page_api.Command) !void {
        const self = try active(raw, owner);
        defer wakeup.notify();
        switch (value) {
            .navigate => |url| {
                try self.controller.queueGet(url);
                self.page_error = null;
                if (self.controller.path == .disconnected and self.controller.reset_warning != .needs_display) try self.reconnect();
            },
            .acknowledge_reset => self.controller.markResetWarningShown(),
            .dismiss_login_notice => _ = self.controller.takeLoginNotice(),
            .reconnect => try self.reconnect(),
            .stop => {
                if (self.controller.path == .connecting) {
                    const attempt = self.proxy_attempt orelse return error.WebRouteNotReady;
                    self.disconnect(attempt, "已取消 SSH 连接。");
                    self.destroySurface();
                } else {
                    const surface = try self.readySurface();
                    self.native_navigation_id = (try surface.snapshot()).navigation_id;
                    try surface.stop();
                    self.awaiting_navigation = false;
                    self.controller.stopLoad();
                }
            },
            .back => _ = try (try self.readySurface()).goBack(),
            .forward => _ = try (try self.readySurface()).goForward(),
            .reload => {
                if (self.controller.path == .disconnected) {
                    try self.reconnect();
                } else if (self.controller.failed_url) |url| {
                    try self.controller.queueGet(url);
                    self.page_error = null;
                } else {
                    const surface = try self.readySurface();
                    _ = try surface.reload();
                }
            },
        }
    }

    fn readySurface(self: *Runtime) !*web.Surface {
        if (self.controller.path != .ready or !self.controller.view_ready) return error.WebRouteNotReady;
        return if (self.surface) |*surface| surface else error.WebRouteNotReady;
    }

    fn reconnect(self: *Runtime) !void {
        // Do not rebind an old data store or overlap an unreleased proxy.
        if (self.controller.path == .idle and self.proxy_stopping) return;
        try self.controller.reconnect();
        self.destroySurface();
        self.requestProxyStop();
        self.path_error = null;
        self.page_error = null;
    }

    fn mutateBookmark(raw: *anyopaque, owner: identity.SessionHandle, mutation: bookmarks.Mutation) !void {
        const self = try active(raw, owner);
        if (!self.temporary) return error.SavedBookmarkTransactionRequired;
        var candidate: std.heap.ArenaAllocator = .init(self.allocator);
        defer candidate.deinit();
        switch (try bookmarks.apply(candidate.allocator(), self.bookmark_items, mutation)) {
            .unchanged => {},
            .updated => |result| {
                std.mem.swap(std.heap.ArenaAllocator, &candidate, &self.bookmark_arena);
                self.bookmark_items = result.items;
                wakeup.notify();
            },
        }
    }

    fn snapshot(raw: *anyopaque, owner: identity.SessionHandle, a: std.mem.Allocator) !page_api.Snapshot {
        const self = try active(raw, owner);
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const out = arena.allocator();
        const state = self.surface_state;
        const controller = &self.controller;
        const hops = if (self.route) |*route| route.hops else &.{};
        const route_hops = try out.alloc(page_api.Hop, hops.len);
        for (hops, route_hops) |hop, *copy| copy.* = .{
            .name = try out.dupe(u8, hop.nonsecret_config.name),
            .host = try out.dupe(u8, hop.nonsecret_config.host),
            .port = hop.nonsecret_config.port,
        };
        const current_url = try copyOptional(out, controller.currentUrl());
        const pending_url = try copyOptional(out, controller.pending_url orelse controller.opening_url orelse controller.failed_url);
        const start_url = try copyOptional(out, controller.start_url);
        const title = if (self.surface) |*surface| try surface.copyTitle(out) else null;
        const items = try copyBookmarks(out, self.bookmark_items);
        const active_view = controller.path == .ready and controller.view_ready;
        const waiting_for_cleanup = controller.path == .idle and self.proxy_stopping;
        const generic_error: ?[]const u8 = if (controller.page == .failed) "网页加载失败。" else null;
        const cleanup_unknown = waiting_for_cleanup and self.closeReceipt() == .unknown;
        const error_message: ?[]const u8 = if (cleanup_unknown)
            "旧 SSH 转发仍在清理，请重试。"
        else
            self.path_error orelse self.page_error orelse generic_error;
        return .{
            .arena = arena,
            .path = if (cleanup_unknown) .disconnected else if (waiting_for_cleanup) .connecting else controller.path,
            .page = controller.page,
            .reset_warning = controller.reset_warning,
            .login_notice = controller.show_login_notice and controller.path == .ready and controller.page == .displayed,
            .route_mode = controller.route,
            .url_mode = self.url_mode,
            .current_url = current_url,
            .pending_url = pending_url,
            .start_url = start_url,
            .title = title,
            .can_go_back = active_view and state != null and state.?.can_go_back,
            .can_go_forward = active_view and state != null and state.?.can_go_forward,
            .loading = active_view and (controller.page == .loading or (state != null and state.?.loading)),
            .progress = if (state) |native| native.progress else 0,
            .error_message = error_message,
            .bookmarks = items,
            .hops = route_hops,
        };
    }
};

fn nativeChanged() callconv(.c) void {
    wakeup.notify();
}

fn copyOptional(a: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    return if (text) |value| try a.dupe(u8, value) else null;
}

fn copyBookmarks(a: std.mem.Allocator, source: []const bookmarks.Bookmark) ![]const bookmarks.Bookmark {
    const items = try a.alloc(bookmarks.Bookmark, source.len);
    for (source, items) |item, *copy| copy.* = .{
        .id = item.id,
        .title = try a.dupe(u8, item.title),
        .url = try a.dupe(u8, item.url),
    };
    return items;
}

fn proxyError(err: anyerror) []const u8 {
    return switch (err) {
        error.WebProxyUnavailable => "网页 SSH 转发需要 macOS 14 或更新版本。",
        error.PluginCleanupQueueFull => "连接仍在关闭，请稍后重试。",
        error.CredentialMissing, error.AuthenticationInteractionRequired => "SSH 跳板缺少可用凭据，请更新跳板配置后重新打开连接。",
        error.RevisionConflict, error.ConnectionNotFound => "SSH 跳板配置已变更，请重新打开连接。",
        error.HostKeyConfirmationRequired, error.HostKeyRevoked, error.HostKeyChanged => "SSH 跳板主机密钥未通过验证。",
        error.Cancelled => "已取消 SSH 连接。",
        else => "SSH 转发连接失败，请检查路径和跳板认证。",
    };
}

fn surfaceError(err: anyerror) []const u8 {
    return switch (err) {
        error.WebProxyUnavailable, error.WebProxyRequiresMacOS14 => proxyError(error.WebProxyUnavailable),
        error.WebNavigationRejected => "无法打开此网页地址。",
        else => "无法准备网页视图。",
    };
}
