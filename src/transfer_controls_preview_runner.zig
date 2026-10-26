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
    fn batch(_: *anyopaque, targets: []const V.Target, requested: V.TaskAction) !void {
        std.debug.print("TRANSFER_CONTROLS_FIXTURE batch={s} count={d}\n", .{ @tagName(requested), targets.len });
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
    const panel = try V.mountProjection(cx, scope, .{ .presentation = presentation }, .{ .context = fixture, .action = Fixture.action, .batch = Fixture.batch });
    fixture.panel = panel;
    if (presentation == .session_tray) {
        panel.setDirectionFilter(.upload);
        const slot = try ui.box(cx, .{ .position = .absolute, .inset = .{ .top = .{ .px = 60 }, .right = .{ .px = 12 } }, .width = .{ .px = 620 }, .height = .{ .px = 300 }, .direction = .column }, .{});
        try root.appendChild(cx.allocator, slot);
        try slot.appendChild(cx.allocator, panel.root);
    } else try root.appendChild(cx.allocator, panel.root);
    const owner: @import("host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 1 };
    const second: @import("host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(102), .generation = 1 };
    const names = [_][]const u8{ "release.tar.gz", "worker.stdout.log", "worker.yaml", "config.production.json", "db-backup.sql.gz", "checksums.txt", "healthcheck.txt", "release-second-session.tar.gz" };
    const phases = [_]V.Phase{ .running, .running, .queued, .paused, .failed, .succeeded, .succeeded, .queued };
    var tasks: [8]V.Task = undefined;
    for (&tasks, 0..) |*task, i| task.* = .{
        .target = .{ .job = 1042 + i, .attempt = 1, .owner = if (i == 6) second else if (i == 4) .{ .session_id = @fromBackingInt(201), .generation = 1 } else owner },
        .direction = if (i == 1 or i == 4 or i == 6) .download else .upload,
        .name = names[i],
        .owner_label = if (i == 6) "K8s-Node02 #102" else if (i == 4) "DB-Master #201" else "K8s-Node01 #101",
        .local_path = if (i == 0) "/private/var/folders/hb/12753xs57vs9vv2xpy73kcn80000gn/T/zerowork-native-transfer-fixture-long-directory/local/release.tar.gz" else "/tmp/ZeroWork/worker.stdout.log",
        .remote_path = if (i == 0) "/srv/releases/release.tar.gz" else if (i == 1) "/srv/releases/worker.stdout.log" else if (i == 2) "/srv/releases/worker.yaml" else if (i == 3) "/srv/releases/config.production.json" else if (i == 4) "/backup/db-backup.sql.gz" else if (i == 5) "/srv/releases/checksums.txt" else "/srv/releases/healthcheck.txt",
        .phase = phases[i],
        .route = "session #101 · 经 Bastion-01",
        .events = "14:20:01 入队\n14:20:02 开始\n14:20:08 传输中",
        .options = if (i == 0) "断点续传 开 · MD5 关" else "断点续传 开 · MD5 开",
        .event_summary = "14:20:01 入队 · 14:20:02 开始 · 14:20:08 传输中",
        .status_detail = if (i == 4) "连接中断" else if (i == 5) "MD5 一致" else "",
        .total_bytes = if (i == 0) 128 * 1048576 else if (i == 1) 7969178 else if (i == 3) 2150 else if (i == 4) 256 * 1048576 else if (i == 5) 164 else if (i == 6) 48 else 4915,
        .done_bytes = if (i == 0) 85878374 else if (i == 1) 2516582 else if (i == 3) 1024 else if (i == 4) 10 * 1048576 else if (i == 5) 164 else if (i == 6) 48 else 0,
        .speed_bps = if (i == 0) 8598323 else if (i == 1) 3774873 else 0,
    };
    if (presentation == .session_popover or presentation == .session_tray) panel.selected_scope = .{ .session = owner };
    try panel.update(.{ .revision = 1, .rows = &tasks, .scope_label = if (presentation == .session_popover or presentation == .session_tray) "K8s-Node01 #101" else "全部会话", .scope = if (presentation == .session_popover or presentation == .session_tray) .{ .session = owner } else .all, .choices = &.{ .{ .label = "全部会话", .scope = .all }, .{ .label = "K8s-Node01 #101", .scope = .{ .session = owner } }, .{ .label = "K8s-Node02 #102", .scope = .{ .session = second } }, .{ .label = "DB-Master #201", .scope = .{ .session = .{ .session_id = @fromBackingInt(201), .generation = 1 } } }, .{ .label = "无任务会话", .scope = .{ .session = .{ .session_id = @fromBackingInt(202), .generation = 1 } } } } });
    panel.show();
    return root;
}
pub fn main() !void {
    var io: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer io.deinit();
    @import("platform/applog.zig").init(.{}, io.io());
    const app = try App.init(std.heap.c_allocator, .{ .io = io.io(), .window = .{ .width = 860, .height = 480, .title = "ZeroWork · Figma 传输控件预览", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
