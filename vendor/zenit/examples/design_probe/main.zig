/// design_probe: pencil visual design restore verification target.
///
/// Purpose: translate pencil node's exact values to zenit code, render, then use
/// `bun e2e/design_diff.ts` for numeric comparison with the design export.
///
/// Replicates zboard whiteboard app's `Layer Row` component (pencil id `exzZc`); all values
/// come directly from pencil structured read, no eyeballing:
///
///   frame  width:220 height:24 cornerRadius:4 gap:6 padding:[0,6,0,8]
///          alignItems:center fill:#FFFFFF00
///     icon Disclosure  10x10 lucide/chevron-down  #92929B
///     icon Type Icon   13x13 lucide/square-dashed #92929B
///     text Label       Inter 12 normal            #17171B
///     frame Spacer     width:fill_container height:1
///     frame Rail       48x12 layout:none
///       (three 12x12 icons x=0/18/36, enabled:false -> not rendered)
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

/// UI (with style values) in view.yix; this file only handles startup.
const DesignProbe = @import("_view.yix.zig").DesignProbe;

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return ui.view.render(scope, cx, DesignProbe(.{}));
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    // Window size = design node size, screenshot aligns with export without cropping.
    const app = try App.init(gpa.allocator(), .{
        .io = init.io,
        .window = .{ .width = 220, .height = 24, .title = "design probe" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
