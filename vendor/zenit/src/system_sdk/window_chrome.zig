//! Shared window chrome contract. GPU choice is independent of window backend.
const std = @import("std");
const builtin = @import("builtin");
pub const WindowBackend = enum { appkit, win32, wayland, unsupported };
pub const build_environment = .{
    .os = builtin.os.tag,
    .window_backend = switch (builtin.os.tag) {
        .macos => WindowBackend.appkit,
        .windows => WindowBackend.win32,
        .linux => WindowBackend.wayland,
        else => WindowBackend.unsupported,
    },
};
pub const Mode = enum { native, custom, frameless };
pub const ControlsPolicy = enum { automatic, application };
pub const UnsupportedPolicy = enum { use_native, fail };
pub const Custom = struct { controls: ControlsPolicy = .automatic, unsupported: UnsupportedPolicy = .use_native };
pub const Frameless = struct { unsupported: UnsupportedPolicy = .use_native };
pub const Config = union(Mode) { native, custom: Custom, frameless: Frameless };
pub const ControlsOwner = enum { native, framework, application, none };
pub const FallbackReason = enum { none, unsupported_backend, decoration_unverified, missing_native_api, high_contrast };
pub const Appearance = enum(u32) { generic, macos, windows, adwaita, breeze };
pub const Control = enum(u32) { none, minimize, maximize, close };
pub const ControlSide = enum { both, left, right };
/// Experimental until the native presentation/IME acceptance gate is complete.
pub const HeaderVisibility = enum { hidden, autohide, pinned };
pub const ButtonLayout = struct {
    left: [3]Control = @splat(.none),
    right: [3]Control = .{ .minimize, .maximize, .close },
    /// Parse desktop button-layout without adding buttons omitted by the user.
    pub fn parse(text: []const u8) ?ButtonLayout {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
        if (std.mem.indexOfScalar(u8, text[colon + 1 ..], ':') != null) return null;
        var result: ButtonLayout = .{ .right = @splat(.none) };
        var seen: u8 = 0;
        for ([_][]const u8{ text[0..colon], text[colon + 1 ..] }, 0..) |side, i| {
            var words = std.mem.splitScalar(u8, side, ',');
            var count: usize = 0;
            while (words.next()) |word| {
                const token = std.mem.trim(u8, word, " \t\r\n");
                const control: Control = if (std.mem.eql(u8, token, "minimize")) .minimize else if (std.mem.eql(u8, token, "maximize")) .maximize else if (std.mem.eql(u8, token, "close")) .close else continue;
                const bit = @as(u8, 1) << @as(u3, @intCast(@backingInt(control)));
                if (seen & bit != 0) continue;
                seen |= bit;
                (if (i == 0) &result.left else &result.right)[count] = control;
                count += 1;
            }
        }
        return result;
    }
};
pub const Rect = extern struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };
pub const Capabilities = packed struct(u8) {
    custom: bool = false,
    frameless: bool = false,
    minimize: bool = false,
    maximize: bool = false,
    fullscreen: bool = false,

    interactive_move: bool = false,
    interactive_resize: bool = false,
    _padding: u1 = 0,
};
pub const State = struct {
    requested_mode: Mode = .native,
    effective_mode: Mode = .native,
    controls_owner: ControlsOwner = .native,
    fallback_reason: FallbackReason = .none,
    capabilities: Capabilities = .{},
    /// False on older libdecor: actions are requestable, WM support is unobservable.
    wm_capabilities_known: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    fullscreen_transitioning: bool = false,
    active: bool = false,
    tiled: bool = false,
    high_contrast: bool = false,
    fullscreen_header_hosted: bool = false,
    fullscreen_header_visible: bool = false,
    fullscreen_header_presented: bool = false,
    appearance: Appearance = .generic,
    button_layout: ButtonLayout = .{},
    /// Native nonclient hover/press state for application-drawn Windows captions.
    caption_hover: Control = .none,
    caption_pressed: Control = .none,
    /// Radius of the four window corners the client paints itself (Wayland
    /// client-side decoration, libadwaita's 15px); 0 when the platform shapes
    /// the window.
    corner_radius: f32 = 0,
    /// Advances on native configure/transition completion, including refusals.
    state_generation: u32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    scale: f32 = 1,
    /// Fixed, owned values in client logical coordinates; no borrowed native pointers.
    native_controls: [3]Rect = @splat(.{}),
    native_controls_count: u8 = 0,
    /// False means controls exist but their geometry could not be queried.
    controls_geometry_known: bool = true,
};
pub const Action = union(enum) { close, minimize, maximize: bool, toggle_maximize, fullscreen: bool };
/// Explicit regions inherit through noninteractive descendants. Native controls
/// and window resize edges take precedence; overlays and interactive nodes block drag.
pub const Region = enum(u8) { inherit, client, drag, resize_top, resize_bottom, resize_left, resize_top_left, resize_bottom_left, resize_right, resize_top_right, resize_bottom_right, minimize, maximize, close };
pub const Service = struct {
    context: *anyopaque,
    perform: *const fn (*anyopaque, Action) anyerror!void,
};
/// ABI shared with native/window_chrome.h. Flags: maximized/fullscreen/active.
pub const NativeState = extern struct {
    flags: u32 = 0,
    capabilities: u32 = 0,
    controls_count: i32 = 0,
    state_generation: u32 = 0,
    controls: [3]Rect = @splat(.{}),
    appearance: u32 = 0,
    button_layout: [6]u32 = .{ 0, 0, 0, 1, 2, 3 },
    caption_hover: u32 = 0,
    caption_pressed: u32 = 0,
    corner_radius: f32 = 0,
};
pub fn policy(config: Config) UnsupportedPolicy {
    return switch (config) {
        .native => .use_native,
        .custom => |c| c.unsupported,
        .frameless => |c| c.unsupported,
    };
}
pub fn resolve(config: Config, supported: bool, reason: FallbackReason, native_controls: bool) !State {
    var state: State = .{ .requested_mode = std.meta.activeTag(config) };
    if (state.requested_mode != .native and !supported) {
        if (policy(config) == .fail) return error.UnsupportedWindowChrome;
        state.fallback_reason = reason;
        return state;
    }
    state.effective_mode = state.requested_mode;
    state.controls_owner = switch (config) {
        .native => .native,
        .frameless => .none,
        .custom => |c| if (c.controls == .application) .application else if (native_controls) .native else .framework,
    };
    return state;
}
test "unsupported chrome is explicit and strict requests fail" {
    const c: Config = .{ .custom = .{} };
    const s = try resolve(c, false, .decoration_unverified, false);
    try std.testing.expectEqual(Mode.native, s.effective_mode);
    try std.testing.expectEqual(FallbackReason.decoration_unverified, s.fallback_reason);
    try std.testing.expectError(error.UnsupportedWindowChrome, resolve(.{ .frameless = .{ .unsupported = .fail } }, false, .decoration_unverified, false));
    try std.testing.expectEqual(ControlsOwner.framework, (try resolve(c, true, .none, false)).controls_owner);
    try std.testing.expectEqual(ControlsOwner.application, (try resolve(.{ .custom = .{ .controls = .application } }, true, .none, true)).controls_owner);
}
test "button layout preserves omissions, side, order and deduplicates desktop tokens" {
    try std.testing.expectEqual(ButtonLayout{ .right = .{ .close, .none, .none } }, ButtonLayout.parse("appmenu:close").?);
    try std.testing.expectEqual(ButtonLayout{ .left = .{ .close, .minimize, .maximize }, .right = @splat(.none) }, ButtonLayout.parse("close,minimize,maximize:").?);
    try std.testing.expectEqual(ButtonLayout{ .left = .{ .close, .none, .none }, .right = .{ .maximize, .none, .none } }, ButtonLayout.parse("close:close,maximize,maximize").?);
    try std.testing.expectEqual(ButtonLayout{ .right = @splat(.none) }, ButtonLayout.parse(":").?);
    try std.testing.expectEqual(@as(?ButtonLayout, null), ButtonLayout.parse("invalid"));
    try std.testing.expectEqual(@as(?ButtonLayout, null), ButtonLayout.parse("a:b:c"));
}
