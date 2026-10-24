//! Minimal zenit app, counter button.
//!
//! Demonstrates the recommended flow:
//!   - `App.runWith(mountUI)`, one call replaces ~110 lines of boilerplate
//!   - state in a `Signal` created through the mount `Scope`
//!   - `ui.view`: the UI is one declarative tree; `v.fmt` binds the label to
//!     the signal (no node pointer, no buffer, no manual dirty-marking)
//!   - `ui.on.update`: the click handler writes the signal directly
//!   - named css objects resolve tokens and follow theme changes
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

const v = ui.view;
const W = ui.widgets;

const S = @import("styles.zig");

fn inc(n: u32) u32 {
    return n + 1;
}

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const count = try scope.createSignal(u32, 0);

    return v.render(scope, cx, v.col(.{ .style = S.root }, .{
        v.text(.{ .style = S.title }, "Hello, zenit!"),
        v.attrs(.{ .test_id = "counter.increment" }, W.Button(.{
            .label = "Click me",
            .variant = .primary,
            .on_click = ui.on.update(count, inc),
        })),
        v.text(.{ .style = S.caption }, v.fmt("Clicked {d} times", .{count})),
    }));
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .io = init.io,
        .window = .{ .width = 640, .height = 480, .title = "Hello, zenit" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
