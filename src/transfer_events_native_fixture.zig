//! Native production panel + real Manager, deterministic in-memory engine.
//! No SSH/network/file transfer; validates receipt projection and readonly UI.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const backend = @import("transfer/manager.zig");
const V = @import("ui/transfer_manager_view.zig");
const theme = @import("ui/app_theme.zig");
var reference_mode = false;
var selected_theme: theme.Name = .dark;
const Fixture = struct {
    manager: backend.Manager = undefined,
    panel: *V.Panel = undefined,
    fn open(_: *anyopaque, _: backend.JobSpec) !u64 {
        return 101;
    }
    fn cancel(_: *anyopaque, _: u64) void {}
    fn poll(_: *anyopaque) ?backend.EngineProgress {
        return null;
    }
    fn action(_: *anyopaque, _: u64, _: V.Action) void {}
    fn cleanup(self: *Fixture) void {
        self.manager.deinit();
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(selected_theme);
    cx.setTheme(theme.widgetTheme(selected_theme));
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .padding = ui.Padding.all(8), .background = theme.current().app }, .{});
    const f = try scope.createState(Fixture, .{});
    f.manager = try backend.Manager.init(cx.allocator, .{ .ctx = f, .open = Fixture.open, .cancel = Fixture.cancel, .poll = Fixture.poll }, 1, .{});
    try scope.onCleanup(Fixture, f, Fixture.cleanup);
    _ = try f.manager.enqueue(.{ .session_id = 101, .direction = .upload, .sources = &.{"/fixtures/release.tar.gz"}, .local_dir = "/fixtures", .remote_dir = "/srv/releases" });
    f.manager.tick(0);
    f.panel = try V.mountWindow(cx, scope, &f.manager, .{ .context = f, .action = Fixture.action });
    f.panel.options.fill_window = false;
    try root.appendChild(cx.allocator, f.panel.root);
    try f.panel.refresh(0, .{ .window_chunks = 16, .chunk_kb = 64 });
    if (reference_mode) {
        f.panel.manager = null;
        const owner = @import("host/identity.zig").SessionHandle{ .session_id = @fromBackingInt(101), .generation = 1 };
        var rows: [5]V.Task = undefined;
        const names = [_][]const u8{ "release.tar.gz", "worker.stdout.log", "worker.yaml", "config.production.json", "checksums.txt" };
        const phases = [_]V.Phase{ .running, .running, .queued, .paused, .succeeded };
        const done = [_]u64{ 85878374, 2516582, 0, 1024, 164 };
        const total = [_]u64{ 134217728, 7969178, 4915, 2150, 164 };
        for (&rows, 0..) |*row, i| {
            row.* = .{ .target = .{ .job = 1042 + i, .attempt = 1, .owner = owner }, .direction = if (i == 1) .download else .upload, .name = names[i], .owner_label = "K8s-Node01 #101", .local_path = "~/Downloads/ZeroWork/release.tar.gz", .remote_path = try std.fmt.allocPrint(cx.allocator, "/srv/releases/{s}", .{names[i]}), .route = "经 Bastion-01", .phase = phases[i], .done_bytes = done[i], .total_bytes = total[i], .speed_bps = if (i == 0) 8598323 else if (i == 1) 3774874 else 0, .options = "断点续传开 · MD5 等待结果", .event_summary = "14:20:01 入队 · 14:20:02 开始 · 14:20:08 传输中", .events = "14:20:01 入队 · job1042 · session101\n14:20:02 SSH传输连接就绪\n14:20:02 开始上传 /srv/releases/release.tar.gz\n14:20:08 已传81.9MiB / 128MiB · 64%" };
        }
        defer for (rows) |row| cx.allocator.free(row.remote_path);
        const members = [_]@import("host/identity.zig").SessionHandle{owner};
        const choices = [_]V.ScopeChoice{ .{ .label = "全部会话", .scope = .all }, .{ .label = "K8s-Node01 #101", .scope = .{ .session = owner } }, .{ .label = "组 · k8s-nodes", .scope = .{ .sessions = .{ .members = &members, .revision = 1 } } } };
        try f.panel.update(.{ .revision = 2, .rows = &rows, .scope = .{ .session = owner }, .scope_label = "K8s-Node01 #101", .choices = &choices });
    }
    f.panel.show();
    return root;
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--reference")) {
            reference_mode = true;
        } else if (std.mem.eql(u8, arg, "--theme")) {
            selected_theme = std.meta.stringToEnum(theme.Name, args.next() orelse return error.InvalidArgument) orelse return error.InvalidArgument;
        } else return error.InvalidArgument;
    }
    const app = try App.init(std.heap.c_allocator, .{ .io = init.io, .window = .{ .width = 926, .height = 594, .min_width = 620, .min_height = 360, .title = "ZeroWork · Transfer Events Fixture", .titlebar = .custom_inset, .titlebar_height = 0, .hide_native_controls = true } });
    defer app.deinit();
    if (app.font_manager.findFont(.{ .family = "Menlo", .size = 10.5, .weight = .regular, .style = .normal })) |font| {
        font.setScaleFactor(app.scale);
        app.font_selector.mono_fonts[0] = font;
        app.font_selector.mono_count = 1;
    } else |_| {}
    try app.runWith(mount);
}
