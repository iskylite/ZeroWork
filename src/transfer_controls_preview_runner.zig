//! Production shared transfer-row fixture. Frozen tasks only; no filesystem or network IO.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const V = @import("ui/transfer_manager_view.zig");
const theme = @import("ui/app_theme.zig");
const options = @import("preview_options");
const Fixture = struct {
    panel: ?*V.Panel = null,
    fn reopen(self: *Fixture) void {
        self.panel.?.show();
    }
    fn action(_: *anyopaque, target: V.Target, requested: V.TaskAction) !void {
        std.debug.print("TRANSFER_CONTROLS_FIXTURE action={s} job={d}\n", .{ @tagName(requested), target.job });
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(.dark);
    _ = theme.setMaterialVisible(false);
    cx.setTheme(theme.widgetTheme(.dark));
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .background = theme.current().surface_1 }, .{});
    const fixture = try scope.createState(Fixture, .{});
    const reopen = try ui.widgets.Button(.{ .label = "重新打开传输预览", .on_click = cx.on(Fixture, fixture, Fixture.reopen), .base_style = .{ .position = .absolute, .inset = .{ .left = .{ .px = 20 }, .top = .{ .px = 20 } }, .height = .{ .px = 30 } } }).mount(scope, cx);
    reopen.meta.ownership.meta.test_id = "transfer.preview.reopen";
    try root.appendChild(cx.allocator, reopen);
    const presentation = std.meta.stringToEnum(V.Presentation, options.presentation) orelse .global_popover;
    const panel = try V.mountProjection(cx, scope, .{ .presentation = presentation }, .{ .context = fixture, .action = Fixture.action });
    fixture.panel = panel;
    if (presentation == .session_tray) {
        panel.setDirectionFilter(.upload);
        const slot = try ui.box(cx, .{ .position = .absolute, .inset = .{ .top = .{ .px = 60 }, .right = .{ .px = 12 } }, .width = .{ .px = 620 }, .height = .{ .px = 300 }, .direction = .column }, .{});
        try root.appendChild(cx.allocator, slot);
        try slot.appendChild(cx.allocator, panel.root);
    } else try root.appendChild(cx.allocator, panel.root);
    var tasks: [3]V.Task = undefined;
    for (&tasks, 0..) |*task, i| task.* = .{ .target = .{ .job = i + 1, .attempt = 1, .owner = .{ .session_id = @fromBackingInt(101), .generation = 1 } }, .direction = .upload, .name = if (i == 2) "production-database-backup-2026-10-26.tar.gz" else "release.tar.gz", .owner_label = "生产 #101", .local_path = "/tmp/release.tar.gz", .remote_path = "/srv/releases/release.tar.gz", .phase = if (presentation == .session_tray or i == 0) .running else if (i == 1) .conflict else .failed, .status_detail = if (i == 2 and presentation != .session_tray) "目标目录不可写，请检查权限" else "", .total_bytes = 100, .done_bytes = 40 };
    try panel.update(.{ .revision = 1, .rows = &tasks });
    panel.show();
    return root;
}
pub fn main() !void {
    var io: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer io.deinit();
    @import("platform/applog.zig").init(.{}, io.io());
    const app = try App.init(std.heap.c_allocator, .{ .io = io.io(), .window = .{ .width = 860, .height = 480, .title = "ZeroWork · 单行传输控件预览", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
