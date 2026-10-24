// GENERATED FILE, do not edit: generated from spinner.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Spinner view. Drawing and keyframes in styles.yss, tests in mod.zig.
const ui = @import("../../ui.zig");
const S = @import("_styles.yss.zig");

/// Rotating loading animation (Material Design circular progress style): self-drawn arc, redrawn
/// per frame by frame clock, not drawn outside viewport.
/// W.Spinner(.{ .size = 24 }); color defaults to theme accent.
pub fn Spinner(args: anytype) ui.view.ComponentOf(__yix_Spinner) {
    return ui.view.component(__yix_Spinner, ui.reactive.props.coerce(SpinnerProps, args));
}
pub const SpinnerProps = struct {
    size: ui.Source(f32) = .{ .value = 20 },
    stroke_width: ui.Source(f32) = .{ .value = 3 },
    color: ui.Source(?ui.Color) = .{ .value = null },
};
fn __yix_Spinner(__yix_props: SpinnerProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const size = __yix_props.size;
    const strokeWidth = __yix_props.stroke_width;
    const color = __yix_props.color;
    const ring = __yix_d1: {
        const __yix_T = @TypeOf(S.Ring{ .size = size.peek(), .stroke_width = strokeWidth.peek(), .color = color.peek() });
        break :__yix_d1 try scope.derive(__yix_T, .{ .size = size, .strokeWidth = strokeWidth, .color = color, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return S.Ring{ .size = __yix_ctx.size.get(), .stroke_width = __yix_ctx.strokeWidth.get(), .color = __yix_ctx.color.get() };
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.canvas(.{ .style = S.container.of(.{ .size = size, .stroke_width = strokeWidth }), .a11y = .{ .role = .progressbar }, }, ui.view.paint(.{ .data = ring, .animate = true, }, S.drawArc)));
    __yix_root.meta.ownership.meta.component_name = "Spinner";
    return __yix_root;

}

//# yix-map-data [[372,367]]

//# yix-map spinner.yix
