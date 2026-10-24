/// virtual_list_perf: showcases ui.widgets.VirtualList rendering 100k rows
///
/// Key feel (Apple Silicon):
///   - regardless of list size (10, 10k, 100k, 1M), render cost is nearly constant
///   - scroll 60fps, no frame drops
///   - cold open doesn't stall (VirtualList only constructs viewport + overscan ~50
///     Nodes)
///
/// UI in view.yix: row is a Yix component (`Row`), hooked via
/// `VirtualList(...).rows({}, row)`; row memo is destroyed with its row scope when
/// scrolled out. This file just starts.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const VirtualListPerf = @import("_view.yix.zig").VirtualListPerf;

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return ui.view.render(scope, cx, VirtualListPerf(.{}));
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .io = init.io,
        .window = .{ .width = 720, .height = 600, .title = "100k Virtual List" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
