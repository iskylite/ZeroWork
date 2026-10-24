const ui = @import("ui");
comptime {
    _ = ui.cva(.{ .compound = .{.{ .when = .{}, .style = .{ ._hover = .{ ._focus = .{} } } }} });
}
