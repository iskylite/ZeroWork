//! Isolated production view with local journal/ledger facts, without networking.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const P = @import("ui/connection_progress_view.zig");
const ssh = @import("proto/ssh/session.zig");
const theme = @import("ui/app_theme.zig");
var scene: []const u8 = "direct";
const direct = [_]P.Hop{.{ .name = "ScaleX40-AI01", .host = "10.2.209.201", .user = "root" }};
const routed = [_]P.Hop{ .{ .name = "Bastion-01", .host = "b1.example", .user = "admin" }, .{ .name = "Bastion-02", .host = "b2.example", .user = "admin" }, direct[0] };
const long_direct = [_]P.Hop{.{ .name = "ScaleX40-AI01 · production-east-primary-cluster", .host = "2001:db8:1234:5678:abcd:ef01:2345:6789", .user = "operations-administrator", .port = 2222 }};
const Fixture = struct {
    cx: *ui.Cx,
    view: *P.View = undefined,
    result: *ui.Node,
    attempt: u64 = 1,
    failed: bool = false,
    releasing: bool = false,
    cancelled: bool = false,
    route: bool = false,
    long: bool = false,
    pending: bool = true,
    fn cancel(raw: *anyopaque, _: P.OperationKey) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.cancelled = true;
        self.failed = false;
        self.pending = true;
        self.cx.requestRedraw();
    }
    fn retry(raw: *anyopaque, _: P.OperationKey) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.attempt += 1;
        self.failed = false;
        self.releasing = false;
        self.pending = true;
        try self.result.setTextContent(self.cx.allocator, "已调用原连接的重试操作");
        self.cx.requestRedraw();
    }
    fn close(raw: *anyopaque, _: P.OperationKey) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.result.setTextContent(self.cx.allocator, "已关闭连接结果") catch {};
        self.cx.requestRedraw();
    }
    fn copy(raw: *anyopaque, _: P.OperationKey, text: []const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (text.len == 0) return error.EmptyLogs;
        try self.result.setTextContent(self.cx.allocator, "已收到本次连接日志");
        self.cx.requestRedraw();
    }
    fn frame(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (!self.pending) return .done;
        self.pending = false;
        self.show() catch |err| std.log.err("progress fixture: {s}", .{@errorName(err)});
        return .needs_layout;
    }
    fn show(self: *Fixture) !void {
        const hops: []const P.Hop = if (self.long) &long_direct else if (self.route) &routed else &direct;
        const key: P.OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(1), .generation = 1 } }, .operation_id = 1, .attempt_id = self.attempt };
        var journal: P.progress.Journal = .{};
        journal.begin(self.attempt);
        const current: usize = if (self.route) 1 else 0;
        for (0..current) |hop| journal.record(.{ .attempt = self.attempt, .timestamp_ns = 0, .hop = hop, .hop_count = hops.len, .host = hops[hop].host, .port = 22, .phase = .ready, .status = .succeeded });
        for ([_]P.progress.Phase{ .transport, .handshake, .host_key, .authentication }) |phase| journal.record(.{ .attempt = self.attempt, .timestamp_ns = @as(i128, @intCast(journal.count)) * 100 * std.time.ns_per_ms, .hop = current, .hop_count = hops.len, .host = hops[current].host, .port = 22, .phase = phase, .status = if (self.failed and phase == .authentication) .failed else .succeeded, .failure = if (self.failed and phase == .authentication) error.AuthenticationFailed else null });
        if (!self.failed) journal.record(.{ .attempt = self.attempt, .timestamp_ns = 520 * std.time.ns_per_ms, .hop = current, .hop_count = hops.len, .host = hops[current].host, .port = 22, .phase = .shell, .status = .started });
        var ledger = try ssh.ResourceLedger.init(key, hops.len);
        for (0..hops.len) |hop| _ = ledger.record(key, hop, .session, if (self.releasing) .releasing else if (self.failed or self.cancelled) .released else .owned);
        try self.view.show(.{ .key = key, .hops = hops, .journal = journal.snapshot(), .local_ready = true, .state = if (self.cancelled) .cancelled else if (self.failed) .failed else .connecting, .cleanup = if (self.releasing) .releasing else if (self.failed or self.cancelled) .released else .not_started, .resources = ledger.snapshot() });
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(.dark);
    _ = theme.setMaterialParameters(0, 0);
    cx.setTheme(theme.widgetTheme(.dark));
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .background = theme.baseColors().app, .padding = ui.Padding.all(24) }, .{});
    const result = try ui.text(cx, "", .{ .font_size = 12, .color = theme.current().fg_2 });
    result.meta.ownership.meta.test_id = "fixture.result";
    try root.appendChild(cx.allocator, result);
    const self = try scope.createState(Fixture, .{ .cx = cx, .result = result, .route = !std.mem.eql(u8, scene, "direct") and !std.mem.eql(u8, scene, "long"), .long = std.mem.eql(u8, scene, "long"), .failed = std.mem.eql(u8, scene, "failed") or std.mem.eql(u8, scene, "releasing"), .releasing = std.mem.eql(u8, scene, "releasing") });
    self.view = try P.View.mount(cx, scope, .{ .context = self, .cancel = Fixture.cancel, .retry = Fixture.retry, .close = Fixture.close, .copy_logs = Fixture.copy });
    try cx.addAfterLayoutHook(self, Fixture.frame);
    return root;
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    scene = args.next() orelse "direct";
    const app = try App.init(std.heap.c_allocator, .{ .io = init.io, .window = .{ .width = 1280, .height = 720, .min_width = 620, .min_height = 480, .title = "ZeroWork · Connection progress preview", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
