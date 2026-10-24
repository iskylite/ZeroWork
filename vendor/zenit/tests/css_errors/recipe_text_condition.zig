const ui = @import("ui");
test {
    const R = ui.sva(.{
        .slots = .{.label},
        .variants = .{ .done = .{ .false = .{}, .true = .{ .label = .{ ._hover = .{ .color = .accent } } } } },
    });
    _ = R.Slot(.label).resolveText(.{ .done = false }, .{}, &ui.theme.light);
}
