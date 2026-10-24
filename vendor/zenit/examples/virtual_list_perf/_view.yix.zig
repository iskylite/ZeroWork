// GENERATED FILE, do not edit: generated from view.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");
const W = ui.widgets;

pub const ITEM_COUNT: usize = 100_000;
const ITEM_HEIGHT: f32 = 32;

/// Styles in styles.yss
const S = @import("_styles.yss.zig");

/// One row. VirtualList gives each row a child scope, when row scrolls out of viewport it's
/// recycled with row's memo.
fn Row(args: anytype) ui.view.ComponentOf(__yix_Row) {
    return ui.view.component(__yix_Row, ui.reactive.props.coerce(RowProps, args));
}
const RowProps = struct {
    index: ui.Source(usize),
};
fn __yix_Row(__yix_props: RowProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const index = __yix_props.index;
    const odd = __yix_d1: {
        const __yix_T = @TypeOf(index.peek() % 2 == 1);
        break :__yix_d1 try scope.derive(__yix_T, .{ .index = index, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.index.get() % 2 == 1;
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = S.Row.of(.{ .odd = odd }), }, .{
            ui.view.box(.{ .style = .{ .width = .{ .px = 70 } }, }, .{
                ui.view.text(.{ .style = S.index, }, ui.view.fmt("#" ++ ui.view.yixFormat(@TypeOf(index), ""), .{ index, })),
            }),
            ui.view.text(.{ .style = S.title, }, ui.view.fmt("Item " ++ ui.view.yixFormat(@TypeOf(index), "") ++ " — Lorem ipsum dolor sit amet", .{ index, })),
        }));
    __yix_root.meta.ownership.meta.component_name = "Row";
    return __yix_root;

}

fn row(i: usize) @TypeOf(Row(.{ .index = 0 })) {
    return Row(.{ .index = i });
}

/// VirtualList's rows is row function passed via .rows(ctx, row) method chain, M0 template lacks
/// render prop,
/// here use normal Zig component (takes props, returns element) threaded into template.
fn ItemList(props: struct { count: usize, item_height: f32 }) @TypeOf(W.VirtualList(.{}).rows({}, row)) {
    return W.VirtualList(.{ .item_count = props.count, .item_height = props.item_height, .overscan = 5 }).rows({}, row);
}

pub fn VirtualListPerf(args: anytype) ui.view.ComponentOf(__yix_VirtualListPerf) {
    return ui.view.component(__yix_VirtualListPerf, ui.reactive.props.coerce(VirtualListPerfProps, args));
}
pub const VirtualListPerfProps = struct {
};
fn __yix_VirtualListPerf(__yix_props: VirtualListPerfProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const thousands = @as(f32, @floatFromInt(ITEM_COUNT)) / 1000;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ .style = S.root, }, .{
            ui.view.row(.{ .style = S.header, }, .{
                ui.view.text(.{ .style = S.header_text, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(thousands), ".0") ++ "k items rendered through ui.widgets.VirtualList", .{ thousands, })),
            }),
            ui.view.templateAttrs(.{ .style = S.list, }, ItemList(.{ .count = ITEM_COUNT, .item_height = ITEM_HEIGHT, })),
        }));
    __yix_root.meta.ownership.meta.component_name = "VirtualListPerf";
    return __yix_root;

}

//# yix-map-data [[305,300],[2032,1161]]

//# yix-map view.yix
