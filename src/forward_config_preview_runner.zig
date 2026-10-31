//! Isolated real native forwarding form. No profile, credentials or network IO.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const Config = @import("ui/socks_config_view.zig");
const Info = @import("ui/socks_info_view.zig");
const theme = @import("ui/app_theme.zig");
var info_preview = false;
const InfoController = struct {
    view: ?*Info.View = null,
    trigger: *ui.Node = undefined,
    fn action(_: *anyopaque, _: Info.Action) void {}
    fn configured(self: *InfoController) void {
        self.view.?.update(.{ .configured = true, .host = "ScaleX40-AI01", .port = 1081 }) catch {};
        self.view.?.showNode(self.trigger);
    }
    fn empty(self: *InfoController) void {
        self.view.?.update(.{}) catch {};
        self.view.?.showNode(self.trigger);
    }
    fn failed(self: *InfoController) void {
        self.view.?.update(.{ .configured = true, .state = .failed, .host = "ScaleX40-AI01", .port = 1081, .error_text = "端口已被占用，请修改监听端口后重试。" }) catch {};
        self.view.?.showNode(self.trigger);
    }
};
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
    if (info_preview) {
        const controller = try scope.createState(InfoController, .{});
        const toolbar = try ui.hstack(cx, .{ .gap = 8 }, .{});
        toolbar.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 20 }, .top = .{ .px = 20 } } });
        inline for (.{
            .{ "已配置", cx.on(InfoController, controller, InfoController.configured) },
            .{ "空状态", cx.on(InfoController, controller, InfoController.empty) },
            .{ "失败", cx.on(InfoController, controller, InfoController.failed) },
        }, 0..) |entry, index| {
            const button = try ui.widgets.Button(.{ .label = entry[0], .on_click = entry[1] }).mount(scope, cx);
            button.meta.ownership.meta.test_id = ([_][]const u8{ "forward.preview.configured", "forward.preview.empty", "forward.preview.failed" })[index];
            try toolbar.appendChild(cx.allocator, button);
        }
        try root.appendChild(cx.allocator, toolbar);
        controller.trigger = try ui.widgets.Button(.{ .label = "端口转发", .on_click = cx.on(InfoController, controller, InfoController.configured) }).mount(scope, cx);
        controller.trigger.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .right = .{ .px = 20 }, .bottom = .{ .px = 12 } } });
        try root.appendChild(cx.allocator, controller.trigger);
        controller.view = try Info.mount(cx, scope, .{ .context = controller, .action = InfoController.action });
        if (!controller.view.?.portaled) try root.appendChild(cx.allocator, controller.view.?.wrapper);
        controller.configured();
        return root;
    }
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
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| if (std.mem.eql(u8, arg, "--info")) {
        info_preview = true;
    };
    var io: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer io.deinit();
    @import("platform/applog.zig").init(.{}, io.io());
    const app = try App.init(std.heap.c_allocator, .{ .io = io.io(), .window = .{ .width = 860, .height = 480, .title = "ZeroWork · 转发原生控件验收", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
