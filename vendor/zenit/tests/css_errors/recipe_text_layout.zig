const ui = @import("ui");
test {
    const R = ui.cva(.{ .base = .{ .padding = .space200 } });
    _ = R.resolveText(.{}, .{}, &ui.theme.light);
}
