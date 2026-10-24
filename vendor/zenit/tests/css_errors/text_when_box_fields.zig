//! <text> v.when can only toggle text fields; when css with box fields goes in v.when, box fields
//! silently dropped, now compile error.
const ui = @import("ui");
test {
    _ = try ui.view.render(undefined, undefined, ui.view.text(.{ .style = ui.view.when(true, ui.css(.{ .padding = 4, .color = .accent })) }, "x"));
}
