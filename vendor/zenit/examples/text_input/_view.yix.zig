// GENERATED FILE, do not edit: generated from view.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const std = @import("std");
const ui = @import("ui");
const W = ui.widgets;

/// Styles in styles.yss
const S = @import("_styles.yss.zig");

/// Controlled input parent: via ui.split, each proposed change converts to uppercase and applies.
/// Cursor should stop after insertion point when inserting mid-string (not jump to end), Cmd+Z goes
/// back before conversion.
const UpperCode = struct {
    code: *ui.Signal([]const u8),
    buf: [64]u8 = undefined,

    fn write(self: *UpperCode, proposed: []const u8) void {
        const n = @min(proposed.len, self.buf.len);
        for (proposed[0..n], 0..) |c, i| self.buf[i] = std.ascii.toUpper(c);
        self.code.set(self.buf[0..n]);
    }
};

/// Force-uppercase input: state object must be created at mount (imperative), so written as normal
/// Zig component, used as tag in template.
fn mountCodeInput(_: struct {}, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const upper = try cx.bindState(UpperCode, .{ .code = try scope.createText("ABCD", .{}) });
    return ui.view.render(scope, cx, ui.view.attrs(.{ .test_id = "input.code" }, W.Input(.{
        .label_text = "Code (forced upper case)",
        .value = ui.split(upper.code, ui.on.call(upper, UpperCode.write)),
        .width = 320,
    })));
}
fn CodeInput(props: struct {}) ui.view.ComponentOf(mountCodeInput) {
    return ui.view.component(mountCodeInput, props);
}

pub fn TextInputDemo(args: anytype) ui.view.ComponentOf(__yix_TextInputDemo) {
    return ui.view.component(__yix_TextInputDemo, ui.reactive.props.coerce(TextInputDemoProps, args));
}
pub const TextInputDemoProps = struct {
};
fn __yix_TextInputDemo(__yix_props: TextInputDemoProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ .style = S.root, }, .{
            ui.view.text(.{ .style = S.title, }, ui.view.fmt("Text Input Demo", .{ })),
            ui.view.text(.{ .style = S.hint, }, ui.view.fmt("Tab between fields. Try IME (中文/日本語/한국어) too.", .{ })),
            ui.view.templateAttrs(.{ .test_id = "input.name", }, W.Input(.{ .label_text = "Name", .placeholder = "Your name", .width = 320, })),
            ui.view.templateAttrs(.{ .test_id = "input.email", }, W.Input(.{ .label_text = "Email", .placeholder = "you@example.com", .input_type = .email, .width = 320, })),
            ui.view.templateAttrs(.{ .test_id = "input.password", }, W.Input(.{ .label_text = "Password", .placeholder = "••••••••", .input_type = .password, .width = 320, })),
            CodeInput(.{ }),
            ui.view.templateAttrs(.{ .test_id = "input.notes", }, W.Textarea(.{ .label_text = "Notes", .placeholder = "Anything you want to remember…", .rows = 6, .width = 480, })),
        }));
    __yix_root.meta.ownership.meta.component_name = "TextInputDemo";
    return __yix_root;

}

//# yix-map-data [[1399,1394]]

//# yix-map view.yix
