// GENERATED FILE, do not edit: generated from counter.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");
const Button = ui.widgets.Button;
/// Styles in styles.yss
const S = @import("_styles.yss.zig");

pub fn Counter(args: anytype) ui.view.ComponentOf(__yix_Counter) {
    return ui.view.component(__yix_Counter, ui.reactive.props.coerce(CounterProps, args));
}
pub const CounterProps = struct {
    start: ui.Source(u32) = .{ .value = 0 },
};
fn __yix_Counter(__yix_props: CounterProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const start = __yix_props.start;
    const count = try scope.createSignalFor(u32, start.peek());
    const doubled = __yix_d1: {
        const __yix_T = @TypeOf(count.peek() * 2);
        break :__yix_d1 try scope.createMemo(__yix_T, .{ .count = count, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.count.get() * 2;
        } }.__yix_compute);
    };
    const even = __yix_d2: {
        const __yix_T = @TypeOf(count.peek() % 2 == 0);
        break :__yix_d2 try scope.createMemo(__yix_T, .{ .count = count, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.count.get() % 2 == 0;
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ .style = S.root, }, .{
            ui.view.text(.{ .style = S.title, }, ui.view.fmt("Reactive Counter", .{ })),
            ui.view.text(.{ .style = S.counter_text, }, ui.view.fmt("count = " ++ ui.view.yixFormat(@TypeOf(count), ""), .{ count, })),
            ui.view.text(.{ .style = S.derived_text, }, ui.view.fmt("doubled = " ++ ui.view.yixFormat(@TypeOf(doubled), ""), .{ doubled, })),
            ui.view.row(.{ .style = S.Badge.of(.{ .even = even }), }, .{
                ui.view.lazyIf(even, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ .style = S.badge_text, }, ui.view.fmt("even", .{ })) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { _ = __yix_b1_1; return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.text(.{ .style = S.badge_text, }, ui.view.fmt("odd", .{ })) }); } }.__yix_b),
            }),
            ui.view.row(.{ .style = S.button_row, }, .{
                ui.view.textChild(Button, .{ .variant = .primary, .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .count = count, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.count.set(__yix_ctx.count.peek() + (1));  } }.__yix_run)), }, "+1", .{
                    ui.view.text(.{}, ui.view.fmt("+1", .{ })),
                }),
                ui.view.textChild(Button, .{ .variant = .secondary, .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .count = count, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.count.set(0);  } }.__yix_run)), }, "Reset", .{
                    ui.view.text(.{}, ui.view.fmt("Reset", .{ })),
                }),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "Counter";
    return __yix_root;

}

//# yix-map-data [[128,123]]

//# yix-map counter.yix
