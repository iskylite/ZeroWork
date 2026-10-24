const std = @import("std");
const ui = @import("ui");
const zenit_app = @import("zenit_app");
const consumer_options = @import("consumer_options");
const App = zenit_app.App;

comptime {
    const expected = if (consumer_options.external_icons)
        "untitled"
    else
        consumer_options.icon_set;
    if (!std.mem.eql(u8, ui.system_icons.provider_name, expected)) {
        @compileError("Zenit did not attach the selected icon provider");
    }
}

fn mountUI(cx: *ui.Cx, _: *ui.Scope) anyerror!*ui.Node {
    _ = ui.system_icons.check;
    return ui.text(cx, "package consumer", .{});
}

pub fn main(init: std.process.Init) !void {
    // The package matrix launches the linked binary without opening a native
    // window. Real-window behavior remains covered by storybook E2E; this path
    // proves a downstream executable can start after consuming the package.
    if (init.environ_map.contains("ZENIT_PACKAGE_SMOKE_EXIT")) return;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    if (init.environ_map.contains("ZENIT_PACKAGE_MULTI_WINDOW")) {
        var application = zenit_app.MultiWindowApp.init(gpa.allocator(), .{});
        defer application.deinit();
        _ = try application.createWindowWith(.{ .io = init.io,
            .window = .{ .width = 320, .height = 200, .title = "Package Consumer A" },
        }, mountUI);
        _ = try application.createWindowWith(.{ .io = init.io,
            .window = .{ .width = 320, .height = 200, .title = "Package Consumer B" },
        }, mountUI);
        try application.run();
        return;
    }

    const app = try App.init(gpa.allocator(), .{
        .io = init.io,
        .window = .{ .width = 320, .height = 200, .title = "Package Consumer" },
    });
    defer app.deinit();
    try app.runWith(mountUI);
}
