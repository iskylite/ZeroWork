//! Isolated real native forwarding form. No profile, credentials or network IO.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const Config = @import("ui/socks_config_view.zig");
const theme = @import("ui/app_theme.zig");
const Controller = struct {
    view: ?*Config.View = null,
    fn save(raw: *anyopaque, draft: Config.Draft) void {
        const self: *Controller = @ptrCast(@alignCast(raw));
        self.view.?.setSuccess(if (draft.mode == .socks5) "SOCKS5 参数已校验（此窗口不启动网络）" else "固定转发参数已校验（此窗口不启动网络）");
    }
    fn testConfig(raw: *anyopaque, _: Config.Draft) void {
        const self: *Controller = @ptrCast(@alignCast(raw));
        self.view.?.setError("此独立窗口仅验收原生控件；网络数据通路由真实SSH回环单独验证");
    }
    fn cancel(_: *anyopaque) void {}
    fn exposure(_: *anyopaque, _: []const u8) bool {
        return false;
    }
    fn show(self: *Controller) void {
        self.view.?.show(.{}, &.{.{ .label = "链路末端" }}) catch {};
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(.dark);
    _ = theme.setMaterialVisible(false);
    cx.setTheme(theme.widgetTheme(.dark));
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .background = theme.current().surface_1, .direction = .column, .align_items = .center, .justify = .center }, .{});
    const controller = try scope.createState(Controller, .{});
    const trigger = try ui.widgets.Button(.{ .label = "打开端口转发配置", .on_click = cx.on(Controller, controller, Controller.show) }).mount(scope, cx);
    try root.appendChild(cx.allocator, trigger);
    const view = try Config.View.mount(cx, scope, .{ .context = controller, .save = Controller.save, .test_cb = Controller.testConfig, .cancel = Controller.cancel, .confirm_exposure = Controller.exposure });
    controller.view = view;
    view.setOwner("原生控件验收 · 无网络", 1);
    if (!view.portaled) try root.appendChild(cx.allocator, view.root);
    controller.show();
    return root;
}
pub fn main() !void {
    var io: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer io.deinit();
    @import("platform/applog.zig").init(.{}, io.io());
    const app = try App.init(std.heap.c_allocator, .{ .io = io.io(), .window = .{ .width = 860, .height = 480, .title = "ZeroWork · 转发原生控件验收", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
