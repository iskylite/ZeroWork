//! Main-thread navigation state. The session owns the path and WebView;
//! attaching or removing a renderer never creates a new website data store.
const std = @import("std");
const identity = @import("../../host/identity.zig");
const urls = @import("urls.zig");

pub const RouteMode = @import("config.zig").RouteMode;
pub const PathState = enum { idle, connecting, ready, disconnected, closed };
pub const PageState = enum { blank, loading, displayed, failed };
pub const RequestMethod = enum { get, other_or_unknown };
pub const ResetWarning = enum { none, needs_display, shown };

pub const View = struct {
    owner: identity.SessionHandle,
    generation: u64,
};
pub const RouteAttempt = struct {
    view: View,
    id: u64,
};
pub const Navigation = struct {
    view: View,
    id: u64,
};

pub const Work = union(enum) {
    connect: RouteAttempt,
    // The platform must copy url before the controller is mutated again.
    open_get: struct { navigation: Navigation, url: []const u8 },
};

const Document = struct {
    url: []const u8,
    method: RequestMethod,
};

pub const Controller = struct {
    allocator: std.mem.Allocator,
    owner: identity.SessionHandle,
    route: RouteMode,
    start_url: ?[]const u8,
    view_generation: u64 = 1,
    sequence: u64 = 1,

    path: PathState,
    page: PageState = .blank,
    content_slot_attached: bool = false,
    view_ready: bool = false,
    pending_url: ?[]const u8,
    opening_url: ?[]const u8 = null,
    failed_url: ?[]const u8 = null,
    document: ?Document = null,
    route_attempt: ?RouteAttempt = null,
    navigation: ?Navigation = null,
    navigation_committed: bool = false,
    used_view: bool = false,
    recovering_route: bool = false,
    recover_confirmed_get: bool = false,
    reset_warning: ResetWarning = .none,
    show_login_notice: bool = false,

    /// A null start URL selects manual mode.
    pub fn init(allocator: std.mem.Allocator, owner: identity.SessionHandle, route: RouteMode, start_url: ?[]const u8) !Controller {
        const start = if (start_url) |url| (try urls.normalize(allocator, url)).text else null;
        errdefer if (start) |url| allocator.free(url);
        return .{
            .allocator = allocator,
            .owner = owner,
            .route = route,
            .start_url = start,
            .pending_url = if (start) |url| try allocator.dupe(u8, url) else null,
            .path = if (route == .direct) .ready else .idle,
        };
    }

    pub fn deinit(self: *Controller) void {
        self.close();
        if (self.start_url) |url| self.allocator.free(url);
        self.* = undefined;
    }

    pub fn view(self: *const Controller) View {
        return .{ .owner = self.owner, .generation = self.view_generation };
    }

    pub fn currentUrl(self: *const Controller) ?[]const u8 {
        return if (self.document) |doc| doc.url else null;
    }

    pub fn setContentSlotAttached(self: *Controller, attached: bool) void {
        self.content_slot_attached = attached and self.path != .closed;
    }

    /// The route can start with an empty Zenit slot. Navigation requires a
    /// WebView for this generation, configured with the ready path.
    pub fn markViewReady(self: *Controller, key: View) bool {
        if (self.path != .ready or !std.meta.eql(key, self.view())) return false;
        self.view_ready = true;
        return true;
    }

    /// Address submission, selecting a bookmark and returning to the preset all
    /// use this queue. While connecting, only the last accepted URL is opened.
    pub fn queueGet(self: *Controller, input: []const u8) !void {
        if (self.path == .closed) return error.SessionClosed;
        const url = try urls.normalize(self.allocator, input);
        self.clearUrl(&self.pending_url);
        self.clearUrl(&self.failed_url);
        self.pending_url = url.text;
    }

    /// Dispatch at most one effect. Resize, redraw and reattachment can poll
    /// freely once the initial target has been handed to the platform.
    pub fn nextWork(self: *Controller) !?Work {
        if (!self.content_slot_attached) return null;
        switch (self.path) {
            .idle => {
                if (self.pending_url == null and !self.recovering_route) return null;
                const attempt: RouteAttempt = .{ .view = self.view(), .id = try self.allocateSequence() };
                self.route_attempt = attempt;
                self.path = .connecting;
                return .{ .connect = attempt };
            },
            .ready => {
                if (!self.view_ready) return null;
                const url = self.pending_url orelse return null;
                const navigation = try self.beginNavigation();
                self.pending_url = null;
                self.opening_url = url;
                return .{ .open_get = .{ .navigation = navigation, .url = url } };
            },
            .connecting, .disconnected, .closed => return null,
        }
    }

    pub fn routeReady(self: *Controller, attempt: RouteAttempt) bool {
        if (self.path != .connecting or !self.matchesAttempt(attempt)) return false;
        self.path = .ready;
        self.recovering_route = false;
        return true;
    }

    pub fn routeFailed(self: *Controller, attempt: RouteAttempt) bool {
        if (self.path != .connecting or !self.matchesAttempt(attempt)) return false;
        self.route_attempt = null;
        self.path = .disconnected;
        return true;
    }

    pub fn cancelRoute(self: *Controller, attempt: RouteAttempt) bool {
        return self.routeFailed(attempt);
    }

    /// A disconnected generation can no longer accept navigation or route
    /// events. Preserve a confirmed displayed GET as a possible recovery target.
    pub fn routeDisconnected(self: *Controller, attempt: RouteAttempt) bool {
        if (self.path != .ready or !self.matchesAttempt(attempt)) return false;
        self.recover_confirmed_get = self.page == .displayed and
            (if (self.document) |doc| doc.method == .get else false);
        self.reset_warning = if (self.used_view) .needs_display else .none;
        self.view_ready = false;
        self.route_attempt = null;
        self.clearNavigation();
        self.path = .disconnected;
        return true;
    }

    /// A renderer calls this only after presenting the effect of reconnecting.
    pub fn markResetWarningShown(self: *Controller) void {
        if (self.path == .disconnected and self.reset_warning == .needs_display) self.reset_warning = .shown;
    }

    /// Start a new generation after explicit user consent. The host retires the
    /// old data store and proxy before creating resources for the new view key.
    pub fn reconnect(self: *Controller) !void {
        if (self.path != .disconnected) return error.PathNotDisconnected;
        if (self.reset_warning == .needs_display) return error.ResetWarningRequired;
        const generation = try identity.advance(self.view_generation);
        if (self.pending_url == null and self.recover_confirmed_get) {
            self.pending_url = try self.allocator.dupe(u8, self.document.?.url);
        }
        self.show_login_notice = self.show_login_notice or self.reset_warning == .shown;
        self.reset_warning = .none;
        self.recover_confirmed_get = false;
        self.used_view = false;
        self.clearUrl(&self.failed_url);
        self.clearDocument();
        self.page = .blank;
        self.view_generation = generation;
        self.path = .idle;
        self.recovering_route = true;
        self.view_ready = false;
    }

    /// Site-driven links/forms/history have a fresh navigation identity. The
    /// platform supplies the confirmed method at commit, including redirects.
    pub fn beginSiteNavigation(self: *Controller, key: View) !Navigation {
        if (!self.view_ready or !std.meta.eql(key, self.view()) or self.path != .ready) return error.InactiveView;
        return self.beginNavigation();
    }

    pub fn didCommit(self: *Controller, navigation: Navigation, actual_url: []const u8, method: RequestMethod) !bool {
        if (!self.matchesNavigation(navigation) or self.navigation_committed) return false;
        const url = try urls.normalize(self.allocator, actual_url);
        self.clearDocument();
        self.document = .{ .url = url.text, .method = method };
        self.navigation_committed = true;
        return true;
    }

    pub fn didFinish(self: *Controller, navigation: Navigation) bool {
        if (!self.matchesNavigation(navigation) or !self.navigation_committed) return false;
        self.page = .displayed;
        self.clearNavigation();
        return true;
    }

    pub fn didFail(self: *Controller, navigation: Navigation) bool {
        if (!self.matchesNavigation(navigation)) return false;
        self.page = .failed;
        self.clearUrl(&self.failed_url);
        self.failed_url = self.opening_url;
        self.opening_url = null;
        self.clearNavigation();
        return true;
    }

    pub fn failPendingLoad(self: *Controller) void {
        self.page = .failed;
        self.clearUrl(&self.failed_url);
        self.failed_url = self.pending_url;
        self.pending_url = null;
    }

    pub fn stopLoad(self: *Controller) void {
        self.clearUrl(&self.pending_url);
        self.clearNavigation();
        self.page = if (self.document != null) .displayed else .blank;
    }

    pub fn observeDisplayedUrl(self: *Controller, actual_url: []const u8) !bool {
        if (self.page != .displayed or self.navigation != null) return false;
        const current = self.document orelse return false;
        const url = try urls.normalize(self.allocator, actual_url);
        if (std.mem.eql(u8, current.url, url.text)) {
            url.deinit(self.allocator);
            return false;
        }
        self.clearDocument();
        // pushState and similar site-driven updates do not prove a network GET.
        self.document = .{ .url = url.text, .method = .other_or_unknown };
        return true;
    }

    pub fn takeLoginNotice(self: *Controller) bool {
        if (!self.show_login_notice or self.path != .ready or self.page != .displayed) return false;
        self.show_login_notice = false;
        return true;
    }

    /// Revoke callback acceptance. The host still owns cleanup and its receipts.
    pub fn close(self: *Controller) void {
        self.path = .closed;
        self.page = .blank;
        self.content_slot_attached = false;
        self.view_ready = false;
        self.route_attempt = null;
        self.clearUrl(&self.pending_url);
        self.clearUrl(&self.failed_url);
        self.clearNavigation();
        self.clearDocument();
    }

    fn beginNavigation(self: *Controller) !Navigation {
        const navigation: Navigation = .{ .view = self.view(), .id = try self.allocateSequence() };
        self.clearUrl(&self.failed_url);
        self.clearNavigation();
        self.navigation = navigation;
        self.page = .loading;
        self.used_view = true;
        return navigation;
    }

    fn allocateSequence(self: *Controller) !u64 {
        const sequence = self.sequence;
        self.sequence = try identity.advance(sequence);
        return sequence;
    }

    fn matchesAttempt(self: *const Controller, attempt: RouteAttempt) bool {
        return if (self.route_attempt) |active| std.meta.eql(active, attempt) else false;
    }

    fn matchesNavigation(self: *const Controller, navigation: Navigation) bool {
        if (self.path != .ready) return false;
        return if (self.navigation) |active| std.meta.eql(active, navigation) else false;
    }

    fn clearUrl(self: *Controller, field: *?[]const u8) void {
        if (field.*) |url| self.allocator.free(url);
        field.* = null;
    }

    fn clearNavigation(self: *Controller) void {
        self.navigation = null;
        self.navigation_committed = false;
        self.clearUrl(&self.opening_url);
    }

    fn clearDocument(self: *Controller) void {
        if (self.document) |document| self.allocator.free(document.url);
        self.document = null;
    }
};

const testing = std.testing;
const test_owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(13) };
const preset = "https://preset.example/";
const selected = "https://bookmark.example/";
const redirected = "https://bookmark.example/redirected";

test "web preset opens once after attaching, and hiding preserves the document" {
    var state = try Controller.init(testing.allocator, test_owner, .direct, preset);
    defer state.deinit();
    try testing.expect(try state.nextWork() == null);
    state.setContentSlotAttached(true);
    try testing.expect(try state.nextWork() == null);
    try testing.expect(state.markViewReady(state.view()));
    const initial = (try state.nextWork()).?.open_get;
    try testing.expectEqualStrings(preset, initial.url);
    try testing.expect(try state.didCommit(initial.navigation, redirected, .get));
    try testing.expect(state.didFinish(initial.navigation));
    state.setContentSlotAttached(false);
    state.setContentSlotAttached(true);
    try testing.expect(try state.nextWork() == null);
    try testing.expectEqualStrings(redirected, state.currentUrl().?);
    try testing.expectEqualStrings(preset, state.start_url.?);
}

test "web manual route awaits a target and a cancelled attempt cannot dispatch" {
    var state = try Controller.init(testing.allocator, test_owner, .ssh, null);
    defer state.deinit();
    state.setContentSlotAttached(true);
    try testing.expectError(error.UnsupportedScheme, state.queueGet("file:///tmp/test"));
    try testing.expect(try state.nextWork() == null);
    try state.queueGet(preset);
    const attempt = (try state.nextWork()).?.connect;
    try state.queueGet(selected);
    try testing.expect(state.cancelRoute(attempt));
    try testing.expect(!state.routeReady(attempt));
    try testing.expectEqual(ResetWarning.none, state.reset_warning);
    try testing.expect(try state.nextWork() == null);
    try state.reconnect();
    try testing.expect(!state.markViewReady(attempt.view));
    const retry = (try state.nextWork()).?.connect;
    try testing.expect(!state.routeReady(attempt));
    try testing.expect(state.routeReady(retry));
    try testing.expect(try state.nextWork() == null);
    try testing.expect(state.markViewReady(retry.view));
    const request = (try state.nextWork()).?.open_get;
    try testing.expectEqualStrings(selected, request.url);
    try testing.expect(try state.didCommit(request.navigation, selected, .get));
    try testing.expect(state.didFinish(request.navigation));
    try testing.expect(!state.takeLoginNotice());
}

test "web reconnect warns before resetting, rejects stale callbacks and restores a confirmed GET" {
    var state = try Controller.init(testing.allocator, test_owner, .ssh, preset);
    defer state.deinit();
    state.setContentSlotAttached(true);
    const attempt = (try state.nextWork()).?.connect;
    try testing.expect(state.routeReady(attempt));
    try testing.expect(state.markViewReady(attempt.view));
    const request = (try state.nextWork()).?.open_get;
    try testing.expect(try state.didCommit(request.navigation, redirected, .get));
    try testing.expect(state.didFinish(request.navigation));
    try testing.expect(state.routeDisconnected(attempt));
    try testing.expectError(error.ResetWarningRequired, state.reconnect());
    try testing.expectEqualStrings(redirected, state.currentUrl().?);
    state.markResetWarningShown();
    try state.reconnect();
    try testing.expect(state.currentUrl() == null);
    const retry = (try state.nextWork()).?.connect;
    try testing.expect(state.routeReady(retry));
    try testing.expect(try state.nextWork() == null);
    try testing.expect(state.markViewReady(retry.view));
    const restore = (try state.nextWork()).?.open_get;
    try testing.expectEqualStrings(redirected, restore.url);
    try testing.expect(!try state.didCommit(request.navigation, preset, .get));
    var foreign = restore.navigation;
    foreign.view.owner.session_id = @fromBackingInt(42);
    try testing.expect(!try state.didCommit(foreign, preset, .get));
    try testing.expect(!state.takeLoginNotice());
    try testing.expect(try state.didCommit(restore.navigation, redirected, .get));
    try testing.expect(state.didFinish(restore.navigation));
    try testing.expect(state.takeLoginNotice());
    try testing.expect(!state.takeLoginNotice());
}

test "web reconnect never replays a POST and an explicit new target supersedes a GET" {
    for ([_]RequestMethod{ .get, .other_or_unknown }) |method| {
        var state = try Controller.init(testing.allocator, test_owner, .ssh, preset);
        defer state.deinit();
        state.setContentSlotAttached(true);
        const attempt = (try state.nextWork()).?.connect;
        try testing.expect(state.routeReady(attempt));
        try testing.expect(state.markViewReady(attempt.view));
        _ = try state.nextWork();
        const site = try state.beginSiteNavigation(state.view());
        try testing.expect(try state.didCommit(site, redirected, method));
        try testing.expect(state.didFinish(site));
        try testing.expect(state.routeDisconnected(attempt));
        if (method == .get) try state.queueGet(selected);
        try testing.expectError(error.ResetWarningRequired, state.reconnect());
        state.markResetWarningShown();
        try state.reconnect();
        const retry = (try state.nextWork()).?.connect;
        try testing.expect(state.routeReady(retry));
        try testing.expect(state.markViewReady(retry.view));
        if (method == .get) {
            const request = (try state.nextWork()).?.open_get;
            try testing.expectEqualStrings(selected, request.url);
            state.close();
            try testing.expect(!try state.didCommit(request.navigation, selected, .get));
        } else {
            try testing.expect(try state.nextWork() == null);
            try testing.expectEqual(PageState.blank, state.page);
        }
    }
}

test "web page failures leave the path intact and late callbacks cannot replace a newer page" {
    var state = try Controller.init(testing.allocator, test_owner, .direct, preset);
    defer state.deinit();
    state.setContentSlotAttached(true);
    try testing.expect(state.markViewReady(state.view()));
    const first = (try state.nextWork()).?.open_get.navigation;
    try state.queueGet(selected);
    const second = (try state.nextWork()).?.open_get.navigation;
    try testing.expect(!try state.didCommit(first, preset, .get));
    try testing.expect(state.didFail(second));
    try testing.expectEqual(PageState.failed, state.page);
    try testing.expectEqual(PathState.ready, state.path);
    try testing.expectEqualStrings(selected, state.failed_url.?);
    try state.queueGet(state.failed_url.?);
    const third = (try state.nextWork()).?.open_get.navigation;
    try testing.expect(try state.didCommit(third, selected, .get));
    try testing.expect(!try state.didCommit(third, redirected, .get));
    try testing.expect(state.didFinish(third));
    try testing.expectEqualStrings(selected, state.currentUrl().?);
    try state.queueGet(preset);
    const stopped = (try state.nextWork()).?.open_get.navigation;
    state.stopLoad();
    try testing.expectEqual(PageState.displayed, state.page);
    try testing.expect(!try state.didCommit(stopped, preset, .get));
    try testing.expectEqualStrings(selected, state.currentUrl().?);
}
