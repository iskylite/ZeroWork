// GENERATED FILE, do not edit: generated from view.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");
const Button = ui.widgets.Button;
/// Stylesheet (styles.yss): JSON token reference + app recipe S.Panel, separated from interface
/// structure.
const S = @import("_styles.yss.zig");

fn emphasisOf(n: u32) S.PanelEmphasis {
    return if (n > 0) .highlight else .neutral;
}

/// Click +1; after clicked, count panel switches to highlight variant (cva variant directly
/// receives computed source).
pub fn HelloButton(args: anytype) ui.view.ComponentOf(__yix_HelloButton) {
    return ui.view.component(__yix_HelloButton, ui.reactive.props.coerce(HelloButtonProps, args));
}
pub const HelloButtonProps = struct {
};
fn __yix_HelloButton(__yix_props: HelloButtonProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const count = try scope.createSignalFor(u32, 0);
    const emphasis = __yix_d1: {
        const __yix_T = @TypeOf(emphasisOf(count.peek()));
        break :__yix_d1 try scope.createMemo(__yix_T, .{ .count = count, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return emphasisOf(__yix_ctx.count.get());
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ .style = S.root, }, .{
            ui.view.text(.{ .style = S.title, }, ui.view.fmt("Hello, zenit!", .{ })),
            ui.view.templateAttrs(.{ .test_id = "hello.increment", }, ui.view.textChild(Button, .{ .variant = .primary, .size = .md, .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .count = count, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.count.set(__yix_ctx.count.peek() + (1));  } }.__yix_run)), }, "Click me", .{
                ui.view.text(.{}, ui.view.fmt("Click me", .{ })),
            })),
            ui.view.box(.{ .style = S.Panel.of(.{ .emphasis = emphasis }), }, .{
                ui.view.text(.{ .test_id = "hello.counter", .style = S.counter_label, }, ui.view.fmt("Clicked " ++ ui.view.yixFormat(@TypeOf(count), "") ++ " times", .{ count, })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "HelloButton";
    return __yix_root;

}

//# yix-map-data [[430,425]]

//# yix-map view.yix
