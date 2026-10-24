// GENERATED FILE, do not edit: generated from view.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");
const Button = ui.widgets.Button;

/// Styles in styles.yss
const S = @import("_styles.yss.zig");

/// Each window mounts one: signal built on that window's own scope, clicking only affects this
/// window.
pub fn WindowUi(args: anytype) ui.view.ComponentOf(__yix_WindowUi) {
    return ui.view.component(__yix_WindowUi, ui.reactive.props.coerce(WindowUiProps, args));
}
pub const WindowUiProps = struct {
    tag: ui.Source([]const u8),
    heading: ui.Source([]const u8),
    button: ui.Source([]const u8),
};
fn __yix_WindowUi(__yix_props: WindowUiProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const tag = __yix_props.tag;
    const heading = __yix_props.heading;
    const button = __yix_props.button;
    const clicks = try scope.createSignalFor(u32, 0);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ .style = S.root, }, .{
            ui.view.text(.{ .style = S.heading, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(heading), ""), .{ heading, })),
            Button(.{ .label = button, .variant = .primary, .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .clicks = clicks, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.clicks.set(__yix_ctx.clicks.peek() + (1));  } }.__yix_run)), }),
            ui.view.text(.{ .style = S.caption, }, ui.view.fmt("[" ++ ui.view.yixFormat(@TypeOf(tag), "") ++ "] clicked " ++ ui.view.yixFormat(@TypeOf(clicks), "") ++ " times", .{ tag, clicks, })),
        }));
    __yix_root.meta.ownership.meta.component_name = "WindowUi";
    return __yix_root;

}

//# yix-map-data [[237,232]]

//# yix-map view.yix
