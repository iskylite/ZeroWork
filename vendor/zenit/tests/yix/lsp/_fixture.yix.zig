// GENERATED FILE, do not edit: generated from fixture.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! yix-lsp smoke fixture: built-in components (hand-written Zig) and this file's Yix components,
//! test property / tag name completion.
const ui = @import("../../../src/ui/ui.zig");
const W = ui.widgets;

pub fn Card2(args: anytype) ui.view.ComponentOf(__yix_Card2) {
    return ui.view.component(__yix_Card2, ui.reactive.props.coerce(Card2Props, args));
}
pub const Card2Props = struct {
    title: ui.Source([]const u8) = .{ .value = "" },
    count: ui.Source(i32) = .{ .value = 0 },
    on_pick: ?ui.Handler(void) = null,
};
fn __yix_Card2(__yix_props: Card2Props, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const title = __yix_props.title;
    const count = __yix_props.count;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(title), "") ++ " " ++ ui.view.yixFormat(@TypeOf(count), ""), .{ title, count, })),
        }));
    __yix_root.meta.ownership.meta.component_name = "Card2";
    return __yix_root;

}

pub fn Demo(args: anytype) ui.view.ComponentOf(__yix_Demo) {
    return ui.view.component(__yix_Demo, ui.reactive.props.coerce(DemoProps, args));
}
pub const DemoProps = struct {
};
fn __yix_Demo(__yix_props: DemoProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            W.Button(.{ .label = "Save", }),
            Card2(.{ .title = "a", }),
            ui.view.row(.{ }, .{ }),
        }));
    __yix_root.meta.ownership.meta.component_name = "Demo";
    return __yix_root;

}

//# yix-map-data [[212,212],[1027,358]]

//# yix-map fixture.yix
