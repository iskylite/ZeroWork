const ui = @import("ui");
comptime {
    _ = ui.sva(.{ .slots = .{.root}, .base = .{ .missing = .{ .gap = .space100 } } });
}
