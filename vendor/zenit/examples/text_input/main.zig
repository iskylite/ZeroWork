/// text_input: showcases ui.widgets.Input and ui.widgets.Textarea
///
/// Key point: these two are the **only** components in zenit depending on text_core
/// (DocCursor / WrapMap / LineCol, see src/ui/components/input/).
///
/// This demo is also the smoke test for the OSS boundary text_core subgraph:
/// if Input/Textarea accidentally pull in framework-boundary dependencies, this example
/// fails to compile along with hello_button/counter_reactive/virtual_list_perf.
///
/// IME (CJK input method): switch to Chinese input and type; the system delivers
/// ime_preedit/ime_commit events via system_sdk straight to ui.Cx.
///
/// UI (with controlled uppercase input) is in view.yix; this file just starts it.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui");
const App = @import("zenit_app").App;
const TextInputDemo = @import("_view.yix.zig").TextInputDemo;

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    // Match widget tokens to the explicit light canvas and heading colors.
    cx.setTheme(&ui.theme.light);
    return ui.view.render(scope, cx, TextInputDemo(.{}));
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = if (comptime builtin.os.tag == .linux) blk: {
        var allow_software = false;
        var validation = false;
        const args = try init.minimal.args.toSlice(init.arena.allocator());
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--allow-software")) allow_software = true else if (std.mem.eql(u8, arg, "--validation")) validation = true else return error.InvalidArgument;
        }
        break :blk try App.init(gpa.allocator(), .{
            .io = init.io,
            .window = .{ .width = 600, .height = 620, .title = "Text Input Demo" },
            .allow_software_gpu = allow_software,
            .require_gpu_validation = validation,
        });
    } else try App.init(gpa.allocator(), .{
        .io = init.io,
        .window = .{ .width = 600, .height = 620, .title = "Text Input Demo" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
