//! Media element tinting has only one source: style wrote icon-color then pass tint= too, who
//! overrides depends on effect order, undo can't recover correct color.
const ui = @import("ui");
test {
    _ = try ui.view.render(undefined, undefined, ui.view.icon(.{ .style = ui.css(.{ .icon_color = .accent }), .tint = ui.Color.WHITE }, ui.icons.check));
}
