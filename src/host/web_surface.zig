//! Main-thread host owner of an ephemeral WebKit instance. Renderer bindings
//! carry identity and geometry only. Only this host adapter handles AppKit.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const identity = @import("identity.zig");

const NativeSurface = opaque {};
const Rect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    fn from(rect: ui.ComputedRect) !Rect {
        if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
            !std.math.isFinite(rect.w) or !std.math.isFinite(rect.h) or rect.w < 0 or rect.h < 0)
        {
            return error.InvalidSurfaceGeometry;
        }
        return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    }
};

/// Return nonzero to keep a keyboard shortcut in Zenit instead of the page.
/// This callback only classifies the event. Zenit later dispatches it normally.
pub const HostKey = *const fn (context: ?*anyopaque, keycode: u16, modifiers: u32) callconv(.c) c_int;
const FocusCallback = *const fn (context: ?*anyopaque) callconv(.c) void;
pub const FocusEntered = struct {
    callback: FocusCallback,
    context: *anyopaque,
};
pub const ChangeCallback = *const fn () callconv(.c) void;

const NativeState = extern struct {
    progress: f64,
    navigation_id: u64,
    url_revision: u64,
    can_go_back: c_int,
    can_go_forward: c_int,
    loading: c_int,
    displayed: c_int,
    failed: c_int,
    ready: c_int,
    committed: c_int,
    committed_get: c_int,
};

extern fn zw_web_surface_supports_proxy() c_int;
extern fn zw_web_surface_create() ?*NativeSurface;
extern fn zw_web_surface_create_proxied(u16, [*]const u8, usize, [*]const u8, usize) ?*NativeSurface;
extern fn zw_web_surface_destroy(*NativeSurface) void;
extern fn zw_web_surface_set_change_callback(*NativeSurface, ?ChangeCallback) void;
extern fn zw_web_surface_sync(*NativeSurface, *anyopaque, Rect, Rect, [*]const Rect, usize, c_int, ?HostKey, ?FocusCallback, ?*anyopaque) c_int;
extern fn zw_web_surface_detach(*NativeSurface) void;
extern fn zw_web_surface_release_focus(*NativeSurface) void;
extern fn zw_web_surface_navigate(*NativeSurface, [*]const u8, usize) c_int;
extern fn zw_web_surface_go_back(*NativeSurface) c_int;
extern fn zw_web_surface_go_forward(*NativeSurface) c_int;
extern fn zw_web_surface_reload(*NativeSurface) c_int;
extern fn zw_web_surface_stop(*NativeSurface) void;
extern fn zw_web_surface_copy_request(*NativeSurface, *Request) c_int;
extern fn zw_web_request_dispose(*Request) void;
extern fn zw_web_surface_request_pending(*NativeSurface, u64) c_int;
extern fn zw_web_surface_reply_request(*NativeSurface, u64, c_int, [*]const u8, usize, [*]const u8, usize) c_int;
extern fn zw_web_surface_cancel_requests(*NativeSurface) void;
extern fn zw_web_surface_state(*NativeSurface) NativeState;
extern fn zw_web_surface_copy_url(*NativeSurface) ?[*:0]u8;
extern fn zw_web_surface_copy_title(*NativeSurface) ?[*:0]u8;

pub fn supportsProxy() bool {
    return zw_web_surface_supports_proxy() != 0;
}

pub const RequestKind = enum(c_int) { alert = 1, confirm, prompt, http_auth, notice };

/// Owns independent copies of public presentation data only. Native completion
/// handlers remain in the bounded main-thread queue until reply or cancellation.
pub const Request = extern struct {
    token: u64,
    navigation_id: u64,
    kind: RequestKind,
    origin: [*:0]u8,
    message: [*:0]u8,
    default_text: [*:0]u8,
    realm: [*:0]u8,

    pub fn deinit(self: *Request) void {
        zw_web_request_dispose(self);
    }
};

pub const Snapshot = struct {
    progress: f64,
    navigation_id: u64,
    url_revision: u64,
    can_go_back: bool,
    can_go_forward: bool,
    loading: bool,
    displayed: bool,
    failed: bool,
    ready: bool,
    committed: bool,
    committed_get: bool,
};

pub const Mount = struct {
    owner: identity.SessionHandle,
    window_id: u64,
    generation: u64,
};

pub const Layout = struct {
    /// All rectangles use Zenit's top-left logical coordinate space. AppKit
    /// owns backing scale and intersects with the actual native window bounds.
    slot: ui.ComputedRect,
    clip: ui.ComputedRect,
    occlusions: []const Rect = &.{},
    visible: bool,
    host_key: ?HostKey = null,
    focus_entered: ?FocusEntered = null,
};

pub const Occlusion = Rect;

pub const Surface = struct {
    native: ?*NativeSurface,
    main_thread: std.Thread.Id,
    owner: identity.SessionHandle,
    mount: ?Mount = null,
    generation: u64 = 0,

    pub fn init(owner: identity.SessionHandle) !Surface {
        return .{
            .native = zw_web_surface_create() orelse return error.WebSurfaceCreationFailed,
            .main_thread = std.Thread.getCurrentId(),
            .owner = owner,
        };
    }

    /// The proxy listener is local. WebKit preserves the destination URL and
    /// keeps its normal local handling of loopback destinations.
    pub fn initProxied(owner: identity.SessionHandle, port: u16, username: []const u8, password: []const u8) !Surface {
        if (!supportsProxy()) return error.WebProxyRequiresMacOS14;
        return .{
            .native = zw_web_surface_create_proxied(port, username.ptr, username.len, password.ptr, password.len) orelse
                return error.WebProxyConfigurationFailed,
            .main_thread = std.Thread.getCurrentId(),
            .owner = owner,
        };
    }

    pub fn setChangeCallback(self: *Surface, callback: ?ChangeCallback) !void {
        zw_web_surface_set_change_callback(try self.nativeOnMain(), callback);
    }

    pub fn deinit(self: *Surface) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread);
        if (self.native) |native| zw_web_surface_destroy(native);
        self.native = null;
        self.mount = null;
    }

    pub fn bind(self: *Surface, owner: identity.SessionHandle, window_id: u64) !Mount {
        _ = try self.nativeOnMain();
        if (!owner.eql(self.owner)) return error.StaleWebSurfaceMount;
        if (window_id == 0 or self.mount != null) return error.WebSurfaceAlreadyBound;
        self.generation = std.math.add(u64, self.generation, 1) catch return error.WebSurfaceGenerationExhausted;
        const mount: Mount = .{ .owner = owner, .window_id = window_id, .generation = self.generation };
        self.mount = mount;
        return mount;
    }

    pub fn sync(self: *Surface, mount: Mount, app: *App, layout: Layout) !void {
        const native = try self.nativeForMount(mount);
        if (app.windowId() != mount.window_id) return error.StaleWebSurfaceMount;
        if (zw_web_surface_sync(
            native,
            app.win.window_ptr,
            try Rect.from(layout.slot),
            try Rect.from(layout.clip),
            layout.occlusions.ptr,
            layout.occlusions.len,
            @intFromBool(layout.visible),
            layout.host_key,
            if (layout.focus_entered) |focus| focus.callback else null,
            if (layout.focus_entered) |focus| focus.context else null,
        ) == 0) return error.WebSurfaceMountFailed;
    }

    /// An unmount retires the renderer binding while the page instance and
    /// website data remain owned by this session.
    pub fn unbind(self: *Surface, mount: Mount) !void {
        zw_web_surface_detach(try self.nativeForMount(mount));
        self.mount = null;
    }

    pub fn releaseFocus(self: *Surface, mount: Mount) !void {
        zw_web_surface_release_focus(try self.nativeForMount(mount));
    }

    pub fn navigate(self: *Surface, url: []const u8) !void {
        if (zw_web_surface_navigate(try self.nativeOnMain(), url.ptr, url.len) == 0) return error.WebNavigationRejected;
    }

    pub fn goBack(self: *Surface) !bool {
        return zw_web_surface_go_back(try self.nativeOnMain()) != 0;
    }

    pub fn goForward(self: *Surface) !bool {
        return zw_web_surface_go_forward(try self.nativeOnMain()) != 0;
    }

    pub fn reload(self: *Surface) !bool {
        return zw_web_surface_reload(try self.nativeOnMain()) != 0;
    }

    pub fn stop(self: *Surface) !void {
        zw_web_surface_stop(try self.nativeOnMain());
    }

    pub fn copyRequest(self: *const Surface) !?Request {
        var request: Request = undefined;
        return switch (zw_web_surface_copy_request(try self.nativeOnMain(), &request)) {
            1 => request,
            0 => null,
            else => error.OutOfMemory,
        };
    }

    pub fn requestPending(self: *const Surface, token: u64) !bool {
        return zw_web_surface_request_pending(try self.nativeOnMain(), token) != 0;
    }

    pub fn replyRequest(self: *Surface, token: u64, accepted: bool, value: []const u8, secret: []const u8) !bool {
        return zw_web_surface_reply_request(try self.nativeOnMain(), token, @intFromBool(accepted), value.ptr, value.len, secret.ptr, secret.len) != 0;
    }

    pub fn cancelRequests(self: *Surface) !void {
        zw_web_surface_cancel_requests(try self.nativeOnMain());
    }

    pub fn snapshot(self: *const Surface) !Snapshot {
        const value = zw_web_surface_state(try self.nativeOnMain());
        return .{
            .progress = value.progress,
            .navigation_id = value.navigation_id,
            .url_revision = value.url_revision,
            .can_go_back = value.can_go_back != 0,
            .can_go_forward = value.can_go_forward != 0,
            .loading = value.loading != 0,
            .displayed = value.displayed != 0,
            .failed = value.failed != 0,
            .ready = value.ready != 0,
            .committed = value.committed != 0,
            .committed_get = value.committed_get != 0,
        };
    }

    pub fn copyUrl(self: *const Surface, allocator: std.mem.Allocator) !?[]u8 {
        const value = zw_web_surface_copy_url(try self.nativeOnMain()) orelse return null;
        defer std.c.free(value);
        return try allocator.dupe(u8, std.mem.span(value));
    }

    pub fn copyTitle(self: *const Surface, allocator: std.mem.Allocator) !?[]u8 {
        const value = zw_web_surface_copy_title(try self.nativeOnMain()) orelse return null;
        defer std.c.free(value);
        return try allocator.dupe(u8, std.mem.span(value));
    }

    fn nativeOnMain(self: *const Surface) !*NativeSurface {
        if (std.Thread.getCurrentId() != self.main_thread) return error.WebSurfaceOffMainThread;
        return self.native orelse error.WebSurfaceClosed;
    }

    fn nativeForMount(self: *const Surface, mount: Mount) !*NativeSurface {
        const native = try self.nativeOnMain();
        const current = self.mount orelse return error.StaleWebSurfaceMount;
        if (!current.owner.eql(mount.owner) or current.window_id != mount.window_id or
            current.generation != mount.generation) return error.StaleWebSurfaceMount;
        return native;
    }
};
