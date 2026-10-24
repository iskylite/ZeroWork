// GENERATED FILE, do not edit: generated from skeleton.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Skeleton view. Styles in styles.yss, shared types and tests in mod.zig.
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");
const S = @import("_styles.yss.zig");
const SkeletonVariant = mod.SkeletonVariant;

/// Loading placeholder skeleton: count skeleton blocks stacked, can have shimmer animation.
/// Skeleton visually means 'content not here yet', AT side conveys via outer busy state (announced
/// once, not N times per block);
/// live=polite lets content actually arriving be announced in passing.
pub fn Skeleton(args: anytype) ui.view.ComponentOf(__yix_Skeleton) {
    return ui.view.component(__yix_Skeleton, ui.reactive.props.coerce(SkeletonProps, args));
}
pub const SkeletonProps = struct {
    variant: ui.Source(SkeletonVariant) = .{ .value = .text },
    width: ui.Source(f32) = .{ .value = 200 },
    height: ui.Source(f32) = .{ .value = 16 },
    animate: ui.Source(bool) = .{ .value = true },
    count: ui.Source(u8) = .{ .value = 1 },
    gap: ui.Source(f32) = .{ .value = 8 },
};
fn __yix_Skeleton(__yix_props: SkeletonProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const variant = __yix_props.variant;
    const width = __yix_props.width;
    const height = __yix_props.height;
    const animate = __yix_props.animate;
    const count = __yix_props.count;
    const gap = __yix_props.gap;
    const bones = __yix_d1: {
        const __yix_T = @TypeOf(@as(usize, @max(count.peek(), 1)));
        break :__yix_d1 try scope.derive(__yix_T, .{ .count = count, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return @as(usize, @max(__yix_ctx.count.get(), 1));
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.box(.{ .style = S.stack.of(.{ .gap = gap }), .a11y = .{ .role = .status, .label = "Loading", .busy = true, .live = "polite" }, }, .{
            ui.view.repeat(.{ .variant = variant, .width = width, .height = height, .animate = animate, }, bones, struct { fn __yix_row(__yix_row_1: anytype, _: usize, __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.box(.{ .style = .{ S.bone.of(.{ .variant = __yix_row_1.variant, .width = __yix_row_1.width, .height = __yix_row_1.height }), ui.view.loop(.{ .period_ms = S.shimmer_period_ms, .on = __yix_row_1.animate }, S.shimmer) }, }, .{ })); } }.__yix_row),
        }));
    __yix_root.meta.ownership.meta.component_name = "Skeleton";
    return __yix_root;

}

//# yix-map-data [[531,526]]

//# yix-map skeleton.yix
