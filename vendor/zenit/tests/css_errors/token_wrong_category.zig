const ui = @import("ui");
test "wrong token category" {
    _ = @TypeOf(ui.css(.{ .padding = ui.theme.refs.color.accent })).box(&ui.theme.modes.light);
}
