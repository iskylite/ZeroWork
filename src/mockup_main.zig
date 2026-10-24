//! Mockup 预览入口（基建，仅由集成者维护；子智能体不得修改）。
//!
//! 用途：`zig build mockup -Dmockup=<name>` 构建单页设计稿预览程序
//! `zig-out/bin/mockup-<name>`，窗口尺寸取自该 mockup 文件的
//! `window_size`/`title` 常量。用于子智能体并行开发时做实机像素级比对。
//!
//! 隔离机制：视图文件由 build.zig 按名字装配为 `mockup_view` 模块导入
//! 本文件 —— 每次构建的 import 图里只有被选中的那一个 mockup 文件，
//! 其他 mockup 的语法/编译错误互不可见（Zig 对 @import 是 AstGen 急切
//! 解析，if 链剪枝挡不住语法错误，所以必须在 build 层装配）。

const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const applog = @import("platform/applog.zig");

const M = @import("mockup_view");

fn mountMock(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return M.mount(cx, scope);
}

pub fn main() !void {
    var io_threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer io_threaded.deinit();
    applog.init(.{}, io_threaded.io());
    applog.info(.app, "ZeroWork mockup preview: {s} ({d}x{d})", .{ M.title, M.window_size.width, M.window_size.height });
    const app = try App.init(std.heap.c_allocator, .{
        .io = io_threaded.io(),
        .window = .{
            .width = M.window_size.width,
            .height = M.window_size.height,
            .title = M.title,
            .titlebar = .custom_inset,
            .titlebar_height = 40,
            .titlebar_drag_right_inset = 220,
        },
    });
    defer app.deinit();
    try app.runWith(mountMock);
}
