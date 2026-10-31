//! Isolated production close Popover; fabricated state, no application data or IO.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const V = @import("ui/ai_close_confirmation_view.zig");
const theme = @import("ui/app_theme.zig");
var selected_theme: theme.Name = .dark;
const Preview = struct {
    cx: *ui.Cx,
    view: ?*V.View = null,
    result: *ui.Node,
    running: bool = true,
    sequence: u64 = 0,
    cid: u8 = 1,
    confirms: usize = 0,
    cancels: usize = 0,
    minimizes: usize = 0,
    fn show(self: *Preview) void {
        self.sequence += 1;
        self.view.?.update(.{ .ticket = .{ .sequence = self.sequence, .conversation_id = .{ .bytes = @splat(self.cid) } }, .running = self.running }) catch {};
        self.cx.requestRedraw();
    }
    fn confirm(raw: *anyopaque, _: V.Ticket) !void {
        const self: *Preview = @ptrCast(@alignCast(raw));
        self.confirms += 1;
        self.running = false;
        try self.report("确认关闭，保留对话和历史");
    }
    fn cancel(raw: *anyopaque, _: V.Ticket) void {
        const self: *Preview = @ptrCast(@alignCast(raw));
        self.cancels += 1;
        self.report("取消关闭，任务继续") catch {};
    }
    fn minimize(self: *Preview) void {
        self.minimizes += 1;
        self.view.?.dismiss();
        self.report("收起助手，任务继续") catch {};
    }
    fn toggle(self: *Preview) void {
        self.running = !self.running;
        self.view.?.dismiss();
        self.report(if (self.running) "任务正在运行" else "助手已就绪") catch {};
    }
    fn replace(self: *Preview) void {
        self.cid +%= 1;
        self.view.?.update(null) catch {};
        self.report("已切换对话，旧确认已撤销") catch {};
    }
    fn report(self: *Preview, label: []const u8) !void {
        const value = try std.fmt.allocPrint(self.cx.allocator, "{s} · confirm {d} · cancel {d} · minimize {d} · running {}", .{ label, self.confirms, self.cancels, self.minimizes, self.running });
        defer self.cx.allocator.free(value);
        try self.result.setTextContent(self.cx.allocator, value);
        self.cx.requestRedraw();
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(selected_theme);
    cx.setTheme(theme.widgetTheme(selected_theme));
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = .{ .top = 40, .left = 16, .right = 16 }, .gap = 16, .background = theme.baseColors().app }, .{});
    root.meta.ownership.meta.test_id = "ai.close.preview";
    const header = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 }, .{});
    try root.appendChild(cx.allocator, header);
    const title = try ui.text(cx, "AI 助手", .{ .font_size = 13, .font_weight = 600, .color = theme.current().fg_1 });
    try header.appendChild(cx.allocator, title);
    try header.appendChild(cx.allocator, try ui.spacer(cx));
    const result = try ui.text(cx, "任务正在运行", .{ .font_size = 12, .line_height = 18.0 / 12.0, .color = theme.current().fg_2, .wrap = .word });
    result.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
    result.meta.ownership.meta.test_id = "ai.close.preview.result";
    const state = try scope.createState(Preview, .{ .cx = cx, .result = result });
    inline for ([_][]const u8{ "minus", "x" }, [_][]const u8{ "ai.minimize", "ai.close" }, [_][]const u8{ "收起助手", "关闭助手" }, [_]*const fn (*Preview) void{ Preview.minimize, Preview.show }) |icon, id, label, action| {
        const button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.get(icon), .icon_size = @as(f32, 14), .a11y_label = label, .base_style = .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .padding = .{}, .background = ui.Color.TRANSPARENT }, .on_click = cx.on(Preview, state, action) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = id;
        try header.appendChild(cx.allocator, button);
        if (std.mem.eql(u8, id, "ai.close")) {
            state.view = try V.View.mount(cx, scope, button, .{ .context = state, .on_confirm = Preview.confirm, .on_cancel = Preview.cancel });
            try header.appendChild(cx.allocator, state.view.?.root);
        }
    }
    try root.appendChild(cx.allocator, result);
    try root.appendChild(cx.allocator, try ui.spacer(cx));
    const controls = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .gap = 8, .flex_shrink = 0, .padding = .{ .bottom = 16 } }, .{});
    inline for ([_][]const u8{ "切换运行状态", "切换对话" }, [_][]const u8{ "ai.close.preview.toggle", "ai.close.preview.replace" }, [_]*const fn (*Preview) void{ Preview.toggle, Preview.replace }) |label, id, action| {
        const button = try ui.widgets.Button(.{ .variant = .secondary, .label = label, .base_style = @import("ui/ai_close_confirmation_styles.zig").button(false), .on_click = cx.on(Preview, state, action) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = id;
        try controls.appendChild(cx.allocator, button);
    }
    try root.appendChild(cx.allocator, controls);
    return root;
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--theme=")) selected_theme = std.meta.stringToEnum(theme.Name, arg[8..]) orelse return error.InvalidTheme else return error.InvalidOption;
    }
    try @import("platform/ui_fonts.zig").register();
    const app = try App.init(std.heap.c_allocator, .{ .io = init.io, .font = .{ .fallback_families = @import("platform/ui_fonts.zig").families }, .window = .{ .width = 320, .height = 360, .title = "ZeroWork Close Confirmation Preview", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
