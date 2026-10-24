const ui = @import("ui");
comptime {
    _ = ui.sva(.{ .slots = .{.root}, .compound = .{.{ .when = .{ .missing = true }, .style = .{} }} });
}
