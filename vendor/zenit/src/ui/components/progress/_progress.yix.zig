// GENERATED FILE, do not edit: generated from progress.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Progress view. Styles and drawing in styles.yss, shared types and tests in mod.zig.
const std = @import("std");
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");
const S = @import("_styles.yss.zig");
const ProgressStatus = mod.ProgressStatus;

/// Determinate mode reports value (AT announces '70%'); indeterminate mode per ARIA spec doesn't
/// report value, announces busy instead
fn a11yOf(indeterminate: bool, percent: f32) ui.A11yProps {
    if (indeterminate) return .{ .role = .progressbar, .busy = true };
    return .{ .role = .progressbar, .value_min = 0, .value_max = 100, .value_now = percent, .value_range = .{ .now = percent, .min = 0, .max = 100 } };
}

/// Progress bar: W.Progress(.{ .value = upload_ratio, .show_text = true }).
/// value (0-100, clamps to range) and status can be signals; indeterminate mode ignores value,
/// gloss stripe sweeps with frame clock.
pub fn Progress(args: anytype) ui.view.ComponentOf(__yix_Progress) {
    return ui.view.component(__yix_Progress, ui.reactive.props.coerce(ProgressProps, args));
}
pub const ProgressProps = struct {
    value: ui.Source(f32) = .{ .value = 0 },
    status: ui.Source(ProgressStatus) = .{ .value = .normal },
    height: ui.Source(f32) = .{ .value = 4 },
    show_text: ui.Source(bool) = .{ .value = false },
    indeterminate: ui.Source(bool) = .{ .value = false },
    width: ui.Source(?f32) = .{ .value = null },
};
fn __yix_Progress(__yix_props: ProgressProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const value = __yix_props.value;
    const status = __yix_props.status;
    const height = __yix_props.height;
    const showText = __yix_props.show_text;
    const indeterminate = __yix_props.indeterminate;
    const width = __yix_props.width;
    const percent = __yix_d1: {
        const __yix_T = @TypeOf(std.math.clamp(value.peek(), 0, 100));
        break :__yix_d1 try scope.derive(__yix_T, .{ .value = value, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return std.math.clamp(__yix_ctx.value.get(), 0, 100);
        } }.__yix_compute);
    };
    const bar = __yix_d2: {
        const __yix_T = @TypeOf(S.Bar{ .status = status.peek(), .height = height.peek() });
        break :__yix_d2 try scope.derive(__yix_T, .{ .status = status, .height = height, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return S.Bar{ .status = __yix_ctx.status.get(), .height = __yix_ctx.height.get() };
        } }.__yix_compute);
    };
    const has_text = __yix_d3: {
        const __yix_T = @TypeOf(showText.peek() and !indeterminate.peek());
        break :__yix_d3 try scope.derive(__yix_T, .{ .showText = showText, .indeterminate = indeterminate, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.showText.get() and !__yix_ctx.indeterminate.get();
        } }.__yix_compute);
    };
    const semantics = __yix_d4: {
        const __yix_T = @TypeOf(a11yOf(indeterminate.peek(), percent.peek()));
        break :__yix_d4 try scope.derive(__yix_T, .{ .indeterminate = indeterminate, .percent = percent, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return a11yOf(__yix_ctx.indeterminate.get(), __yix_ctx.percent.get());
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = S.container.of(.{ .width = width }), .a11y = semantics, }, .{
            ui.view.box(.{ .style = S.track.of(.{ .height = height }), }, .{
                ui.view.lazyIf(indeterminate, .{ .status = status, .height = height, .percent = percent, .bar = bar, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.canvas(.{ .style = S.sweep_area, }, ui.view.paint(.{ .data = __yix_b1_0.bar, .animate = true, }, S.drawBar)) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.box(.{ .style = .{ S.fill.of(.{ .percent = __yix_b1_1.percent, .height = __yix_b1_1.height }), ui.view.styleBy(__yix_b1_1.status, S.fillGradient) }, }, .{ }) }); } }.__yix_b),
            }),
            ui.view.lazyIf(has_text, .{ .percent = percent, }, struct { fn __yix_b(__yix_b2_0: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.text(.{ .style = S.percent_text, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b2_0.percent), ".0") ++ "%", .{ __yix_b2_0.percent, })) }); } }.__yix_b, null),
        }));
    __yix_root.meta.ownership.meta.component_name = "Progress";
    return __yix_root;

}

//# yix-map-data [[910,905]]

//# yix-map progress.yix
