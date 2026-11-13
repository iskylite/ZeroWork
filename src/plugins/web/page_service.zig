//! Main-thread commands and snapshots scoped to one web session.
const std = @import("std");
const typed = @import("../../host/plugin_services.zig");
const identity = @import("../../host/identity.zig");
const access_api = @import("../../host/session_service_access.zig");
const web = @import("../../host/web_surface.zig");
const bookmarks_api = @import("bookmarks.zig");
const config = @import("config.zig");
const nav = @import("navigation.zig");

pub const key: typed.ServiceKey = .{ .name = "web.page", .major = 1 };
pub const definition = typed.Definition.of(VTable, key);

pub const Command = union(enum) {
    navigate: []const u8,
    back,
    forward,
    reload,
    stop,
    reconnect,
    acknowledge_reset,
    dismiss_login_notice,
};

pub const Hop = struct { name: []const u8, host: []const u8, port: u16 };

pub const Forwarding = union(enum) {
    idle,
    connecting,
    listening: u16,
    stopping,
    disconnected,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    path: nav.PathState,
    page: nav.PageState,
    reset_warning: nav.ResetWarning,
    login_notice: bool,
    route_mode: config.RouteMode,
    forwarding: ?Forwarding,
    forwarding_connections: usize = 0,
    forwarding_uploaded: u64 = 0,
    forwarding_downloaded: u64 = 0,
    forwarding_error: []const u8 = "",
    forwarding_logs: []const u8 = "",
    url_mode: config.UrlMode,
    current_url: ?[]const u8,
    pending_url: ?[]const u8,
    start_url: ?[]const u8,
    title: ?[]const u8,
    can_go_back: bool,
    can_go_forward: bool,
    loading: bool,
    progress: f64,
    error_message: ?[]const u8,
    bookmarks: []const bookmarks_api.Bookmark,
    hops: []const Hop,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// The host resolves the concrete window itself. This pair is borrowed for
/// one synchronous host call and must be obtained again on the next update.
pub const SurfaceBinding = struct { surface: *web.Surface, binding: *?web.Mount };

pub const VTable = struct {
    snapshot: *const fn (*anyopaque, identity.SessionHandle, std.mem.Allocator) anyerror!Snapshot,
    attach: *const fn (*anyopaque, identity.SessionHandle) anyerror!u64,
    surface_binding: *const fn (*anyopaque, identity.SessionHandle, u64) anyerror!?SurfaceBinding,
    detach: *const fn (*anyopaque, identity.SessionHandle, u64) void,
    release_focus: *const fn (*anyopaque, identity.SessionHandle, u64) anyerror!void,
    command: *const fn (*anyopaque, identity.SessionHandle, Command) anyerror!void,
    mutate_bookmark: *const fn (*anyopaque, identity.SessionHandle, bookmarks_api.Mutation) anyerror!void,
};

pub const Page = struct {
    access: access_api.SessionServiceAccess,

    pub fn lookup(access: access_api.SessionServiceAccess) !Page {
        const page: Page = .{ .access = access };
        _ = try page.binding();
        return page;
    }

    pub fn snapshot(self: Page, a: std.mem.Allocator) !Snapshot {
        const live = try self.binding();
        return live.vtable.snapshot(live.context, self.access.owner, a);
    }

    pub fn attach(self: Page) !u64 {
        const live = try self.binding();
        return live.vtable.attach(live.context, self.access.owner);
    }

    pub fn surfaceBinding(self: Page, token: u64) !?SurfaceBinding {
        const live = try self.binding();
        return live.vtable.surface_binding(live.context, self.access.owner, token);
    }

    pub fn detach(self: Page, token: u64) void {
        const live = self.binding() catch return;
        live.vtable.detach(live.context, self.access.owner, token);
    }

    pub fn releaseFocus(self: Page, token: u64) !void {
        const live = try self.binding();
        return live.vtable.release_focus(live.context, self.access.owner, token);
    }

    pub fn command(self: Page, value: Command) !void {
        const live = try self.binding();
        try live.vtable.command(live.context, self.access.owner, value);
    }

    pub fn mutateBookmark(self: Page, mutation: bookmarks_api.Mutation) !void {
        const live = try self.binding();
        try live.vtable.mutate_bookmark(live.context, self.access.owner, mutation);
    }

    fn binding(self: Page) !struct { context: *anyopaque, vtable: *const VTable } {
        const found = (try self.access.lookupCurrent(definition)) orelse return error.WebPageUnavailable;
        return .{ .context = found.context, .vtable = try found.borrow(VTable, key, self.access.owner) };
    }
};
