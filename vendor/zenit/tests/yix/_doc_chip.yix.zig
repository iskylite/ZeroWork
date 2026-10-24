// GENERATED FILE, do not edit: generated from doc_chip.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Documentation example (docs/YIX_REFERENCE.md §2.1): Chip component. Changes here must sync docs.
const ui = @import("ui");
const S = @import("_doc_chip.yss.zig");

pub const Tone = enum { neutral, accent };

/// Selectable capsule; when onRemove given, show remove button
pub fn Chip(args: anytype) ui.view.ComponentOf(__yix_Chip) {
    return ui.view.component(__yix_Chip, ui.reactive.props.coerce(ChipProps, args));
}
pub const ChipProps = struct {
    label: ui.Source([]const u8) = .{ .value = "" },
    tone: ui.Source(Tone) = .{ .value = .neutral },
    selected: ui.Model(bool) = .{ .local = false },
    on_change: ?ui.Handler(bool) = null,
    on_remove: ?ui.Handler(void) = null,
    /// Text children of the tag go into this parameter (ui.view.textChild)
    pub const text_child = "label";
};
fn __yix_Chip(__yix_props: ChipProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const label = __yix_props.label;
    const tone = __yix_props.tone;
    const onChange = __yix_props.on_change;
    const onRemove = __yix_props.on_remove;
    const __yix_model_selected = try ui.reactive.resolveModelFor(bool, scope, __yix_props.selected);
    const selected = __yix_model_selected.read;
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = S.Chip.of(.{ .tone = tone, .selected = selected }), .focusable = true, .focus_ring = true, .a11y = .{ .role = .button, .label = label, .selected = selected }, .on_click = try ui.on.bind(scope, .{ .selected = selected, .__yix_model_selected = __yix_model_selected, .onChange = onChange, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.__yix_model_selected.propose(!__yix_ctx.selected.peek(), __yix_ctx.onChange);  } }.__yix_run), }, .{
            ui.view.text(.{ .style = S.label, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(label), ""), .{ label, })),
            ui.view.lazyIf(onRemove != null, .{ .onRemove = onRemove, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.row(.{ .style = S.remove, .a11y = .{ .role = .button, .label = "Remove" }, .on_click = __yix_b1_0.onRemove, }, .{
                    ui.view.text(.{ }, ui.view.fmt("×", .{ })),
                }) }); } }.__yix_b, null),
        }));
    __yix_root.meta.ownership.meta.component_name = "Chip";
    return __yix_root;

}

//# yix-map-data [[281,276]]

//# yix-map doc_chip.yix
