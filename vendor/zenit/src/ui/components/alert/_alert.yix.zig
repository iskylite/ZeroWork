// GENERATED FILE, do not edit: generated from alert.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Alert view. Styles in styles.yss, shared types and tests in mod.zig.
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");
const S = @import("_styles.yss.zig");
const AlertVariant = mod.AlertVariant;

/// Announcement level: error / warning interrupts current speech (assertive), info / success
/// announces after (polite).
/// role=alert alone won't be announced; AT only auto-announces live regions when non-off.
fn liveLevel(v: AlertVariant) []const u8 {
    return switch (v) {
        .@"error", .warning => "assertive",
        .info, .success => "polite",
    };
}

/// Announcement content: announces message if present, otherwise title
fn spoken(title: []const u8, message: []const u8) ?[]const u8 {
    if (message.len > 0) return message;
    if (title.len > 0) return title;
    return null;
}

/// Static message alert (see Notifier for global alerts): info / success / warning / error, can
/// dismiss;
/// title and message can be signals; new content announced via live region.
/// W.Alert(.{ .variant = .warning, .message = status_text })
pub fn Alert(args: anytype) ui.view.ComponentOf(__yix_Alert) {
    return ui.view.component(__yix_Alert, ui.reactive.props.coerce(AlertProps, args));
}
pub const AlertProps = struct {
    variant: ui.Source(AlertVariant) = .{ .value = .info },
    title: ui.Source([]const u8) = .{ .value = "" },
    message: ui.Source([]const u8) = .{ .value = "" },
    closable: ui.Source(bool) = .{ .value = false },
    on_close: ?ui.Handler(void) = null,
    close_icon_asset: ui.Source(?ui.SvgAsset) = .{ .value = null },
};
fn __yix_Alert(__yix_props: AlertProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const variant = __yix_props.variant;
    const title = __yix_props.title;
    const message = __yix_props.message;
    const closable = __yix_props.closable;
    const onClose = __yix_props.on_close;
    const closeIconAsset = __yix_props.close_icon_asset;
    const has_title = __yix_d1: {
        const __yix_T = @TypeOf(title.peek().len != 0);
        break :__yix_d1 try scope.derive(__yix_T, .{ .title = title, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.title.get().len != 0;
        } }.__yix_compute);
    };
    const live = __yix_d2: {
        const __yix_T = @TypeOf(liveLevel(variant.peek()));
        break :__yix_d2 try scope.derive(__yix_T, .{ .variant = variant, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return liveLevel(__yix_ctx.variant.get());
        } }.__yix_compute);
    };
    const live_text = __yix_d3: {
        const __yix_T = @TypeOf(spoken(title.peek(), message.peek()));
        break :__yix_d3 try scope.derive(__yix_T, .{ .title = title, .message = message, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return spoken(__yix_ctx.title.get(), __yix_ctx.message.get());
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = S.Alert.slot(.root, .{ .kind = variant, .titled = has_title }), .a11y = .{ .role = .alert, .live = live, .live_text = live_text }, }, .{
            ui.view.box(.{ .style = S.Alert.slot(.accent, .{ .kind = variant }), }, .{ }),
            ui.view.col(.{ .style = S.content, }, .{
                ui.view.lazyIf(has_title, .{ .title = title, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ .style = S.title, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b1_0.title), ""), .{ __yix_b1_0.title, })) }); } }.__yix_b, null),
                ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(message.peek().len != 0);
        break :__yix_d1 try scope.derive(__yix_T, .{ .message = message, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.message.get().len != 0;
        } }.__yix_compute);
    }, .{ .message = message, }, struct { fn __yix_b(__yix_b2_0: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.text(.{ .style = S.message, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b2_0.message), ""), .{ __yix_b2_0.message, })) }); } }.__yix_b, null),
            }),
            ui.view.lazyIf(closable, .{ .onClose = onClose, .closeIconAsset = closeIconAsset, }, struct { fn __yix_b(__yix_b3_0: anytype, __yix_bs3_0: *ui.Scope, __yix_bc3_0: *ui.Cx, __yix_bk3_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs3_0, __yix_bc3_0, __yix_bk3_0, .{ ui.view.row(.{ .style = S.close, .a11y = .{ .role = .button, .label = "Dismiss" }, .on_click = __yix_b3_0.onClose, }, .{
                    ui.view.lazyIfSome(__yix_b3_0.closeIconAsset, .{ }, struct { fn __yix_b(__yix_b4_0: anytype, asset: anytype, __yix_bs4_0: *ui.Scope, __yix_bc4_0: *ui.Cx, __yix_bk4_0: ui.view.Sink) anyerror!void { _ = __yix_b4_0; return ui.view.emit(__yix_bs4_0, __yix_bc4_0, __yix_bk4_0, .{ ui.view.icon(.{ .style = S.close_icon, }, asset) }); } }.__yix_b, struct { fn __yix_b(__yix_b4_1: anytype, __yix_bs4_1: *ui.Scope, __yix_bc4_1: *ui.Cx, __yix_bk4_1: ui.view.Sink) anyerror!void { _ = __yix_b4_1; return ui.view.emit(__yix_bs4_1, __yix_bc4_1, __yix_bk4_1, .{ ui.view.text(.{ .style = S.close_label, }, ui.view.fmt("x", .{ })) }); } }.__yix_b),
                }) }); } }.__yix_b, null),
        }));
    __yix_root.meta.ownership.meta.component_name = "Alert";
    return __yix_root;

}

//# yix-map-data [[1079,1074]]

//# yix-map alert.yix
