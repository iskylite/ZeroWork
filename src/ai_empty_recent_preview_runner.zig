//! Isolated production welcome state with fabricated recent conversation titles.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const V = @import("ui/ai_empty_view.zig");
const theme = @import("ui/app_theme.zig");
const Fixture = enum { mixed, wide, unbroken };
var fixture: Fixture = .mixed;
var selected_theme: theme.Name = .dark;
var logo_texture: ?u32 = null;
const titles = [_][]const u8{
    "请检查 Nginx 服务的 error 日志，解释这个 SSH 连接超时问题，并给出每一步的排查方法与处理建议 Please inspect the complete application error log and explain the connection timeout in detail",
    "👩🏽‍💻 检查宽字符 ＡＢＣＤＥＦＧ 与中文日志 🧑‍🚀🚀🌍，保留整个原始问题并检查所有错误信息，尤其是终端输出中的启动失败 👩🏽‍💻 检查宽字符 ＡＢＣＤＥＦＧ 与中文日志 🧑‍🚀🚀🌍",
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
};
const Preview = struct {
    cx: *ui.Cx,
    result: *ui.Node,
    fn select(raw: *anyopaque, id: u64) void {
        const self: *Preview = @ptrCast(@alignCast(raw));
        const value = std.fmt.allocPrint(self.cx.allocator, "selected {d}", .{id}) catch return;
        defer self.cx.allocator.free(value);
        self.result.setTextContent(self.cx.allocator, value) catch {};
        self.cx.requestRedraw();
    }
    fn ignore(_: *anyopaque) void {}
    fn replay(self: *Preview) void {
        selected_theme = switch (selected_theme) {
            .dark => .light,
            .light => .sauber,
            .sauber => .dark,
        };
        theme.select(selected_theme);
        self.cx.setTheme(theme.widgetTheme(selected_theme));
        self.cx.requestRedraw();
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(selected_theme);
    cx.setTheme(theme.widgetTheme(selected_theme));
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = .{ .top = 40 }, .background = theme.baseColors().app }, .{});
    const content = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 276 }, .direction = .column, .padding = .{ .left = 14, .right = 14 }, .flex_shrink = 0 }, .{});
    content.meta.ownership.meta.test_id = "ai.empty.preview.content";
    try root.appendChild(cx.allocator, content);
    const result = try ui.text(cx, "selected none", .{ .font_size = 11, .color = theme.current().fg_2 });
    result.meta.ownership.meta.test_id = "ai.empty.preview.result";
    const state = try scope.createState(Preview, .{ .cx = cx, .result = result });
    const welcome = try V.mount(cx, scope, true, .{ .context = state, .logo_texture = logo_texture, .summarize = Preview.ignore, .logs = Preview.ignore, .settings = Preview.ignore, .ollama = Preview.ignore, .select = Preview.select, .recent = &.{ .{ .id = 17, .title = titles[@backingInt(fixture)] }, .{ .id = 29, .title = "普通短标题" } } });
    try content.appendChild(cx.allocator, welcome);
    try root.appendChild(cx.allocator, result);
    const replay = try ui.widgets.Button(.{ .label = "Replay theme", .on_click = cx.on(Preview, state, Preview.replay) }).mount(scope, cx);
    replay.meta.ownership.meta.test_id = "ai.empty.preview.replay";
    try root.appendChild(cx.allocator, replay);
    return root;
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--theme=")) selected_theme = std.meta.stringToEnum(theme.Name, arg[8..]) orelse return error.InvalidTheme else if (std.mem.startsWith(u8, arg, "--fixture=")) fixture = std.meta.stringToEnum(Fixture, arg[10..]) orelse return error.InvalidFixture else return error.InvalidOption;
    }
    try @import("platform/ui_fonts.zig").register();
    const app = try App.init(std.heap.c_allocator, .{ .io = init.io, .font = .{ .fallback_families = @import("platform/ui_fonts.zig").families }, .window = .{ .width = 600, .height = 400, .title = "ZeroWork Recent Conversation Preview", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    var image = try @import("config/background_asset.zig").decode(std.heap.c_allocator, @import("app_icon_assets").ai_assistant, .{});
    defer image.deinit(std.heap.c_allocator);
    logo_texture = try app.renderer.image_renderer.loadTexture(image.width, image.height, image.pixels);
    defer if (logo_texture) |id| app.renderer.image_renderer.unloadTexture(id);
    try app.runWith(mount);
}
