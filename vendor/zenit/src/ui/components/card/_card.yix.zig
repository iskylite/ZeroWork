// GENERATED FILE, do not edit: generated from card.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Card view. Styles in styles.yss, shared types and tests in mod.zig.
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");
const S = @import("_styles.yss.zig");
const CardVariant = mod.CardVariant;

/// Interactive card reports button to AT (name from title; falls back to child text when no title),
/// selected state; display-only card has no semantic node.
fn semanticsOf(interactive: bool, title: []const u8, selected: bool) ?ui.A11yProps {
    if (!interactive) return null;
    return .{ .role = .button, .label = if (title.len > 0) title else null, .selected = selected };
}

/// Card: title / subtitle + content area (children). Pass on_click to make interactive: enter Tab
/// order, report button to AT.
/// ui.view.with(W.Card(.{ .title = "Plan", .selected = is_current, .on_click = pick }), .{ children
/// })
pub fn Card(args: anytype) ui.view.SlottedOf(__yix_Card) {
    return ui.view.slotted(__yix_Card, ui.reactive.props.coerce(CardProps, args));
}
pub const CardProps = struct {
    title: ui.Source([]const u8) = .{ .value = "" },
    subtitle: ui.Source([]const u8) = .{ .value = "" },
    variant: ui.Source(CardVariant) = .{ .value = .default },
    interactive: ui.Source(bool) = .{ .value = false },
    hoverable: ui.Source(bool) = .{ .value = false },
    selected: ui.Source(bool) = .{ .value = false },
    padded: ui.Source(bool) = .{ .value = true },
    width: ui.Source(?f32) = .{ .value = null },
    height: ui.Source(?f32) = .{ .value = null },
    on_click: ?ui.Handler(void) = null,
};
fn __yix_Card(__yix_props: CardProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!ui.view.ViewParts {
    const title = __yix_props.title;
    const subtitle = __yix_props.subtitle;
    const variant = __yix_props.variant;
    const interactive = __yix_props.interactive;
    const hoverable = __yix_props.hoverable;
    const selected = __yix_props.selected;
    const padded = __yix_props.padded;
    const width = __yix_props.width;
    const height = __yix_props.height;
    const onClick = __yix_props.on_click;
    const clickable = onClick != null;
    const is_interactive = __yix_d1: {
        const __yix_T = @TypeOf(interactive.peek() or clickable);
        break :__yix_d1 try scope.derive(__yix_T, .{ .interactive = interactive, .clickable = clickable, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.interactive.get() or __yix_ctx.clickable;
        } }.__yix_compute);
    };
    const lights_up = __yix_d2: {
        const __yix_T = @TypeOf(hoverable.peek() or interactive.peek() or clickable);
        break :__yix_d2 try scope.derive(__yix_T, .{ .hoverable = hoverable, .interactive = interactive, .clickable = clickable, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.hoverable.get() or __yix_ctx.interactive.get() or __yix_ctx.clickable;
        } }.__yix_compute);
    };
    const semantics = __yix_d3: {
        const __yix_T = @TypeOf(semanticsOf(interactive.peek() or clickable, title.peek(), selected.peek()));
        break :__yix_d3 try scope.derive(__yix_T, .{ .interactive = interactive, .clickable = clickable, .title = title, .selected = selected, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return semanticsOf(__yix_ctx.interactive.get() or __yix_ctx.clickable, __yix_ctx.title.get(), __yix_ctx.selected.get());
        } }.__yix_compute);
    };
    var __yix_slot_children: ?ui.view.SlotPoint = null;
    const __yix_root = try ui.view.render(scope, cx, ui.view.box(.{ .style = .{ S.Card.of(.{ .kind = variant, .selected = selected, .hoverable = lights_up }), S.size.of(.{ .width = width, .height = height }) }, .focusable = is_interactive, .a11y = semantics, .on_click = onClick, }, .{
            ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(title.peek().len != 0 or subtitle.peek().len != 0);
        break :__yix_d1 try scope.derive(__yix_T, .{ .title = title, .subtitle = subtitle, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.title.get().len != 0 or __yix_ctx.subtitle.get().len != 0;
        } }.__yix_compute);
    }, .{ .title = title, .subtitle = subtitle, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.box(.{ .style = S.header, }, .{
                    ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(__yix_b1_0.title.peek().len != 0);
        break :__yix_d1 try __yix_bs1_0.derive(__yix_T, .{ .title = __yix_b1_0.title, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.title.get().len != 0;
        } }.__yix_compute);
    }, .{ .title = __yix_b1_0.title, }, struct { fn __yix_b(__yix_b2_0: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.text(.{ .style = S.title, .box = S.title_row, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b2_0.title), ""), .{ __yix_b2_0.title, })) }); } }.__yix_b, null),
                    ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(__yix_b1_0.subtitle.peek().len != 0);
        break :__yix_d1 try __yix_bs1_0.derive(__yix_T, .{ .subtitle = __yix_b1_0.subtitle, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.subtitle.get().len != 0;
        } }.__yix_compute);
    }, .{ .subtitle = __yix_b1_0.subtitle, }, struct { fn __yix_b(__yix_b3_0: anytype, __yix_bs3_0: *ui.Scope, __yix_bc3_0: *ui.Cx, __yix_bk3_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs3_0, __yix_bc3_0, __yix_bk3_0, .{ ui.view.text(.{ .style = S.subtitle, .box = S.subtitle_row, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b3_0.subtitle), ""), .{ __yix_b3_0.subtitle, })) }); } }.__yix_b, null),
                }) }); } }.__yix_b, null),
            ui.view.slotEnd(&__yix_slot_children, ui.view.box(.{ .style = S.Body.of(.{ .padded = padded }), }, .{ })),
        }));
    __yix_root.meta.ownership.meta.component_name = "Card";
    return ui.view.slottedParts(__yix_root, __yix_slot_children, .{ });

}

//# yix-map-data [[843,838]]

//# yix-map card.yix
