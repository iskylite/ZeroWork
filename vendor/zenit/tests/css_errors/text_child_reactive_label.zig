//! Yix <Button>{x}</Button>: Button declares label as Text, interpolated text can't be static text,
//! use label={source}.
const ui = @import("ui");
test {
    _ = ui.view.textChild(ui.widgets.Button, .{}, null, .{ui.view.text(.{}, "x")});
}
