const ui = @import("ui");
comptime {
    _ = ui.css(.{ .color = .accent, .text_color = null });
}
