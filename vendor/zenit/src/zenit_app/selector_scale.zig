//! HiDPI: which FontSelectors to update when scale changes.
//!
//! After the host installs a custom selector via `App.setFontSelector`, text rendering and
//! measurement use `renderer.fonts` (the host's), so a scale change must update it too, not
//! only the built-in `app.font_selector`; otherwise host fonts stay at the old scale after
//! a screen switch (blurry / bearing misaligned). setFontSelector must likewise sync the
//! current scale on install, else the first frame is wrong.
//!
//! Generic on selector type (only requires `setScaleFactor(f32)`), so it can be unit tested
//! without Metal/CoreText.

const std = @import("std");

/// Built-in selector always updates (self.fonts base font attached); active external
/// selector also updates if different from built-in.
pub fn syncSelectorScale(builtin: anytype, active: ?@TypeOf(builtin), scale: f32) void {
    builtin.setScaleFactor(scale);
    if (active) |sel| {
        if (sel != builtin) sel.setScaleFactor(scale);
    }
}

const FakeSelector = struct {
    scale: f32 = 1,
    calls: u32 = 0,
    fn setScaleFactor(self: *FakeSelector, s: f32) void {
        self.scale = s;
        self.calls += 1;
    }
};

test "外来 selector 生效时 scale 变化同时更新它与内建 selector" {
    var builtin: FakeSelector = .{};
    var host: FakeSelector = .{};
    syncSelectorScale(&builtin, &host, 2.0);
    try std.testing.expectEqual(@as(f32, 2.0), builtin.scale);
    try std.testing.expectEqual(@as(f32, 2.0), host.scale);
}

test "未换 selector（active 为 null 或就是内建）只更新一次" {
    var builtin: FakeSelector = .{};
    syncSelectorScale(&builtin, null, 2.0);
    syncSelectorScale(&builtin, &builtin, 3.0);
    try std.testing.expectEqual(@as(f32, 3.0), builtin.scale);
    try std.testing.expectEqual(@as(u32, 2), builtin.calls);
}
