// GENERATED FILE, do not edit: generated from view.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");

/// Styles in styles.yss
const S = @import("_styles.yss.zig");

pub fn Target(args: anytype) ui.view.ComponentOf(__yix_Target) {
    return ui.view.component(__yix_Target, ui.reactive.props.coerce(TargetProps, args));
}
pub const TargetProps = struct {
};
fn __yix_Target(__yix_props: TargetProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ .style = S.root, }, .{
            ui.view.text(.{ .style = S.title, }, ui.view.fmt("Console probe target", .{ })),
        }));
    __yix_root.meta.ownership.meta.component_name = "Target";
    return __yix_root;

}

//# yix-map-data [[95,90]]

//# yix-map view.yix
