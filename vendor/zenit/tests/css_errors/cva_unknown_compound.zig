const ui = @import("ui");
comptime {
    _ = ui.cva(.{ .compound = .{.{ .when = .{ .missing = true }, .style = .{} }} });
}
