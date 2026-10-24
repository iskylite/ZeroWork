//! Isolated visual fixture: actual production SOCKS view, no network or service evidence.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const socks = @import("ui/socks_info_view.zig");
const theme = @import("ui/app_theme.zig");
const options = @import("preview_options");
const Log = @import("platform/applog.zig");
fn ignore(_: *anyopaque, _: socks.Action) void {}
var sink: u8 = 0;
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    const name = std.meta.stringToEnum(theme.Name, options.theme) orelse .dark;
    theme.select(name);
    _ = theme.setMaterialVisible(false);
    cx.setTheme(theme.widgetTheme(name));
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .background = theme.current().surface_1 }, .{});
    const trigger = try ui.box(cx, .{ .position = .absolute, .width = .{ .px = 28 }, .height = .{ .px = 28 }, .inset = .{ .right = .{ .px = 72 }, .bottom = .{ .px = 14 } } }, .{});
    try trigger.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("plug-zap").?, theme.current().fg_2, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 } }));
    try root.appendChild(cx.allocator, trigger);
    const view = try socks.mount(cx, scope, .{ .context = &sink, .action = ignore });
    try root.appendChild(cx.allocator, view.root);
    try view.update(.{ .state = .running, .host = "Bastion-01", .exit = "Bastion-01", .session_id = 201, .port = 1080, .connections = 2, .downloaded = 48444211, .uploaded = 8493466 });
    view.showNode(trigger);
    return root;
}
pub fn main() !void {
    var io: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer io.deinit();
    Log.init(.{}, io.io());
    const app = try App.init(std.heap.c_allocator, .{ .io = io.io(), .window = .{ .width = 720, .height = 440, .title = "SOCKS V2 production view · " ++ options.theme, .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
