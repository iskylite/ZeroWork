const ui = @import("ui");
fn geometry(_: anytype, _: *const ui.ThemeTokens) struct { label: ui.BoxStyle } {
    return .{ .label = .{ .gap = 1 } };
}
test {
    const R = ui.sva(.{ .slots = .{.label}, .derived = geometry });
    _ = R.Slot(.label).resolveText(.{}, .{}, &ui.theme.light);
}
