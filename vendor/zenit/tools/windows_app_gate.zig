//! Compile gate for the public Zenit App constructor on Windows ARM64.
//! The App uses the Direct2D paint-table subset; mount a UI to see pixels.
const std = @import("std");
const zenit_app = @import("zenit_app");

pub fn main(init: std.process.Init) !void {
    const app = try zenit_app.App.init(std.heap.page_allocator, .{
        .io = init.io,
        .clear_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .pump_timeout_ms = 16,
    });
    defer app.deinit();
    try app.run();
}
