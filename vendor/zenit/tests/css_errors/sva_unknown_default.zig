const ui = @import("ui");
comptime {
    _ = ui.sva(.{ .slots = .{.root}, .defaults = .{ .missing = true } });
}
