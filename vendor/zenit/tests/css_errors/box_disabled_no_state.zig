//! Normal host elements' _disabled / _invalid / _selected / _expanded take state from element's
//! state={...} or a11y same-name field;
//! when style uses but neither location gives state, compile error (otherwise style never applied).
//! _focus / _focus_visible driven by node focus, no declaration needed.
const ui = @import("ui");
test {
    const v = ui.view.box(.{ .style = ui.css(.{ ._disabled = .{ .gap = 1 } }) }, .{});
    _ = try ui.view.render(undefined, undefined, v);
}
