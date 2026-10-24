const builtin = @import("builtin");

pub const TitlebarStyle = enum {
    default,
    /// Application content extends into the caption. Native window controls
    /// remain owned by the platform; the application draws its caption body.
    custom_inset,
};

pub const WindowChrome = @import("system_sdk").window_chrome.Config;

/// A native key event offered to `Config.on_key` before UI dispatch.
pub const KeyEvent = struct {
    key: @import("ui").events.KeyCode,
    modifiers: @import("ui").events.Modifiers,
    pressed: bool,
};

/// Initial position of a window.
pub const Placement = enum {
    /// Platform default (AppKit centres on screen, Win32 cascades).
    default,
    /// Centre on `WindowConfig.owner`, slightly above the middle and clamped to
    /// the owner's screen work area. Palette / find panel convention.
    center_on_owner,
};

pub const WindowConfig = struct {
    min_width: u32 = 0,
    min_height: u32 = 0,
    /// macOS custom tool windows may supply their own caption controls.
    hide_native_controls: bool = false,
    width: if (builtin.os.tag == .windows) u32 else u16 = 800,
    height: if (builtin.os.tag == .windows) u32 else u16 = 600,
    title: [:0]const u8 = if (builtin.os.tag == .windows) "Zenit" else "zenit",
    /// New API takes precedence. Null translates the legacy titlebar settings.
    chrome: ?WindowChrome = null,
    titlebar: TitlebarStyle = .default,
    titlebar_height: f32 = 52,
    titlebar_drag_right_inset: f32 = 0,
    /// Experimental AppKit host prototype; other backends reject visible policies.
    /// Final host preference/fallback contract is not frozen yet.
    fullscreen_header: @import("system_sdk").window_chrome.HeaderVisibility = .hidden,
    /// Owner window (MultiWindowApp only). An owned window stays above its
    /// owner, comes forward with it, never floats over other applications, and
    /// is closed with it. Use with `chrome = .frameless` for panels. Linux
    /// keeps an independent window for now.
    owner: ?@import("system_sdk").events.WindowId = null,
    placement: Placement = .default,
};

pub fn requestedChrome(config: WindowConfig) WindowChrome {
    // Legacy hidden-control windows already configure their AppKit host at
    // creation, including zero-height custom captions used by native fixtures.
    if (config.chrome) |chrome| return chrome;
    if (builtin.os.tag == .macos and config.hide_native_controls) return .native;
    return switch (config.titlebar) {
        .default => .native,
        // Legacy custom_inset was a no-op on Linux; opt in through chrome.
        .custom_inset => if (builtin.os.tag == .linux) .native else .{ .custom = .{} },
    };
}

test "legacy hidden native controls allow a zero height caption and explicit chrome wins" {
    const std = @import("std");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expectEqual(.native, std.meta.activeTag(requestedChrome(.{ .hide_native_controls = true, .titlebar = .custom_inset, .titlebar_height = 0 })));
    try std.testing.expectEqual(.frameless, std.meta.activeTag(requestedChrome(.{ .hide_native_controls = true, .titlebar = .custom_inset, .titlebar_height = 0, .chrome = .{ .frameless = .{} } })));
}
