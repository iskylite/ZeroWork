const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const Counter = @import("_counter.yix.zig").Counter;
fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return ui.view.render(scope, cx, Counter(.{}));
}
pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const app = try App.init(gpa.allocator(), .{ .io = init.io, .window = .{ .width = 480, .height = 400, .title = "Yix Counter" } });
    defer app.deinit();
    try app.runWith(mountUI);
}
