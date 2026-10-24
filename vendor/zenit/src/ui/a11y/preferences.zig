//! System a11y display preferences (process-level). Design in docs/A11Y_ARCHITECTURE.md 7.7.
//!
//! macOS preferences are user/process-level (NSWorkspace accessibilityDisplay*), not
//! window-specific, so this is process state, same class as render_engine.current_frame_dt_ms. Each
//! Cx checks version() at render start to decide if full-tree invalidation is needed and updates
//! its own Signal (core.zig `syncA11yPreferences`).
//!
//! Consumers (all are central choke points, so components need no changes):
//!   * reduce_motion: displacement transitions (translate / scale / rotate / width) complete
//!     instantly; color and opacity gradients preserved (Apple HIG: reduced motion doesn't mean no
//!     animation; dissolve transitions are safe for vestibular-sensitive users). Overlay
//!     slides/scales zeroed, only fade in/out remains;
//!   * reduce_transparency: glass no longer blurs/refracts background; node's own semi-transparent
//!     background lifted to near opaque (Apple system materials behavior under this setting).
//!
//! Platform injects reader via `system_reader`; native side calls exported
//! `zenit_a11y_preferences_changed` when system settings change. Tests and manual QA use
//! `ZENIT_A11Y_PREFS=reduce_motion,reduce_transparency,...` env var to stack (without changing
//! user's system settings).

const std = @import("std");

pub const Preferences = packed struct(u8) {
    reduce_motion: bool = false,
    reduce_transparency: bool = false,
    increase_contrast: bool = false,
    differentiate_without_color: bool = false,
    invert_colors: bool = false,
    _pad: u3 = 0,

    pub fn fromBits(raw: u32) Preferences {
        return @bitCast(@as(u8, @truncate(raw & 0x1F)));
    }

    pub fn bits(self: Preferences) u8 {
        return @bitCast(self);
    }

    pub fn merge(a: Preferences, b: Preferences) Preferences {
        return @bitCast(a.bits() | b.bits());
    }
};

var g_current: Preferences = .{};
var g_version: u32 = 0;

/// Platform injection: read system's current value (bit layout same as Preferences). null =
/// platform unsupported.
pub var system_reader: ?*const fn () callconv(.c) u32 = null;

pub fn current() Preferences {
    return g_current;
}

/// Incremented each time preference actually changes; Cx notes its seen version, syncs if mismatch.
pub fn version() u32 {
    return g_version;
}

pub fn reduceMotion() bool {
    return g_current.reduce_motion;
}

pub fn reduceTransparency() bool {
    return g_current.reduce_transparency;
}

pub fn increaseContrast() bool {
    return g_current.increase_contrast;
}

/// Direct set (tests, or platform already calculated). Version not incremented if value unchanged.
pub fn set(p: Preferences) void {
    if (p.bits() == g_current.bits()) return;
    g_current = p;
    g_version +%= 1;
}

/// Parse `ZENIT_A11Y_PREFS`: comma-separated pref names, unknown names ignored.
pub fn parseOverride(text: []const u8) Preferences {
    var p = Preferences{};
    var it = std.mem.tokenizeAny(u8, text, ", ");
    while (it.next()) |name| {
        inline for (@import("zenit_reflection").fields(Preferences)) |field| {
            if (field.type == bool and std.mem.eql(u8, name, field.name)) @field(p, field.name) = true;
        }
    }
    return p;
}

fn envOverride() Preferences {
    // getEnvVarOwned not posix.getenv: Windows env block is WTF-16, posix.getenv unavailable there.
    // Value is just comma-separated names, fixed stack buffer sufficient; overlength treated as no
    // override.
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const text = @import("zenit_environment").getOwned(fba.allocator(), "ZENIT_A11Y_PREFS") catch return .{};
    return parseOverride(text);
}

/// Re-read system value and stack env var overrides. Return whether preference changed.
pub fn refresh() bool {
    const before = g_version;
    const system: Preferences = if (system_reader) |read| Preferences.fromBits(read()) else .{};
    set(system.merge(envOverride()));
    return g_version != before;
}

/// Native side called on NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification.
export fn zenit_a11y_preferences_changed() void {
    _ = refresh();
}

test "Preferences: 位布局与平台约定一致，parseOverride 只认已知名字" {
    try std.testing.expectEqual(@as(u8, 1), (Preferences{ .reduce_motion = true }).bits());
    try std.testing.expectEqual(@as(u8, 2), (Preferences{ .reduce_transparency = true }).bits());
    try std.testing.expectEqual(@as(u8, 4), (Preferences{ .increase_contrast = true }).bits());
    try std.testing.expectEqual(@as(u8, 8), (Preferences{ .differentiate_without_color = true }).bits());
    try std.testing.expectEqual(@as(u8, 16), (Preferences{ .invert_colors = true }).bits());
    const p = parseOverride("reduce_motion, bogus,reduce_transparency");
    try std.testing.expect(p.reduce_motion and p.reduce_transparency and !p.increase_contrast);
    // High bits cannot leak into padding.
    try std.testing.expectEqual(@as(u8, 0x1F), Preferences.fromBits(0xFFFF_FFFF).bits());
}

test "set: 值不变不递增版本" {
    const saved = g_current;
    defer set(saved);
    set(.{});
    const v0 = version();
    set(.{});
    try std.testing.expectEqual(v0, version());
    set(.{ .reduce_motion = true });
    try std.testing.expect(version() != v0);
    try std.testing.expect(reduceMotion());
}
