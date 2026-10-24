const ui = @import("ui");
test "typography belongs to text" {
    _ = @TypeOf(ui.css(.{ .typography = .{} })).box(&ui.theme.modes.light);
}
