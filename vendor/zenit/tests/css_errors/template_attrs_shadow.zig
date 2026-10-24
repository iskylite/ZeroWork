//! Yix template component element's style merged via attrs onto root node; when component also has
//! style param must error (else param never reaches).
const ui = @import("ui");
const Props = struct { style: u8 = 0 };
fn mountX(_: Props, _: *ui.Scope, _: *ui.Cx) anyerror!*ui.Node {
    unreachable;
}
test {
    _ = ui.view.templateAttrs(.{ .style = ui.css(.{ .gap = 1 }) }, ui.view.Component(mountX, Props){ .props = .{} });
}
