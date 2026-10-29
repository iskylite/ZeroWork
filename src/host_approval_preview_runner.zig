//! Isolated production host-approval component acceptance. No model/network
//! request or user configuration is read. Buttons exercise the real Broker.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const approval = @import("ai/host_approval.zig");
const host = @import("ai/host_tools.zig");
const identity = @import("host/identity.zig");
const theme = @import("ui/app_theme.zig");
const Card = @import("ui/ai_host_approval_view.zig");
var preview_kind: approval.SubjectKind = .network_url;
var long_url = false;
var preview_route = false;
var preview_theme: theme.Name = .dark;
var preview_transparency: f32 = 0;
const Preview = struct {
    cx: *ui.Cx,
    broker: approval.Broker = .{},
    view: ?*Card.View = null,
    result: *ui.Node,
    pending_refresh: bool = false,
    fn decide(raw: *anyopaque, sequence: u64, hash: [32]u8, approved: bool) !void {
        const self: *Preview = @ptrCast(@alignCast(raw));
        try self.broker.decide(sequence, hash, approved);
        try self.result.setTextContent(self.cx.allocator, if (approved) "已批准此调用 · 独立宿主审批" else "已拒绝 · 零派发");
        self.pending_refresh = true;
        self.cx.requestRedraw();
    }
    fn chooseRoute(raw: *anyopaque, sequence: u64, hash: [32]u8, route: approval.routing.Route) !void {
        const self: *Preview = @ptrCast(@alignCast(raw));
        try self.broker.chooseRoute(sequence, hash, route);
        self.pending_refresh = true;
        self.cx.requestRedraw();
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Preview = @ptrCast(@alignCast(raw));
        if (!self.pending_refresh) return .done;
        self.pending_refresh = false;
        if (self.view) |view| view.update(self.broker.snapshot()) catch {};
        return .needs_layout;
    }
    fn cleanup(self: *Preview) void {
        self.broker.stop();
        self.view = null;
        self.cx.removeAfterLayoutHook(self);
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(preview_theme);
    _ = theme.setMaterialParameters(preview_transparency, 0);
    cx.setTheme(theme.widgetTheme(preview_theme));
    try @import("ui/layer_materials.zig").Policy.mount(cx, scope);
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .background = theme.current().surface_1, .padding = .{ .top = 40 } }, .{});
    root.meta.ownership.meta.test_id = "host_approval.preview";
    const result = try ui.text(cx, "本机网络请求尚未发出", .{ .font_size = 11, .color = theme.current().fg_2 });
    result.meta.ownership.meta.test_id = "host_approval.preview.result";
    const state = try scope.createState(Preview, .{ .cx = cx, .result = result });
    try scope.onCleanup(Preview, state, Preview.cleanup);
    const context: host.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 };
    try state.broker.configure(context, 3);
    const extra = try cx.allocator.alloc(u8, if (long_url) 2048 else 0);
    defer cx.allocator.free(extra);
    for (extra, 0..) |*byte, index| byte.* = "release-notes/"[index % 14];
    const url = try std.mem.concat(cx.allocator, u8, &.{ "https://example.com/docs/", extra, "release-notes?version=0.2.6" });
    defer cx.allocator.free(url);
    const json = try std.json.Stringify.valueAlloc(cx.allocator, .{ .url = if (preview_kind == .network_url) url else "preview arguments; no network action" }, .{});
    defer cx.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, cx.allocator, json, .{});
    defer parsed.deinit();
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json, &hash, .{});
    const invocation: host.Invocation = .{ .context = context, .authority = switch (preview_kind) {
        .network_url => .local_network_read,
        .lifecycle => .lifecycle,
        .terminal_command => .execution_control,
    }, .operation_id = 1, .turn_id = 1, .call_id = "preview-host-call", .tool_id = switch (preview_kind) {
        .network_url => "host.fetch_url",
        .lifecycle => "host.open_session",
        .terminal_command => "host.run_in_terminal",
    }, .arguments = parsed.value, .arguments_json = json, .arguments_hash = hash, .canonical_arguments_hash = try @import("ai/canonical_arguments.zig").digest(cx.allocator, parsed.value) };
    _ = try state.broker.beginSubject(invocation, switch (preview_kind) {
        .network_url => .{ .kind = .network_url, .target = url, .detail = url },
        .lifecycle => .{ .kind = .lifecycle, .target = "当前组 · 排障", .detail = "从现有 SSH 会话复用连接，新建工作终端；reuse_only；空闲后关闭。", .impact = "将创建本任务的工作终端并加入当前组；不执行命令，不关闭来源会话。" },
        .terminal_command => .{ .kind = .terminal_command, .target = "工作终端 · app-prod-01", .detail = "pwd; git status --short", .impact = "在当前工作终端提交此命令，输出保留在终端记录中。", .route = if (preview_route) .{ .proposed = .batch, .choice = .{ .route = .batch, .source = .{ .session = .{ .session_id = @fromBackingInt(1), .generation = 1 } } }, .target = .{ .session_id = @fromBackingInt(1), .generation = 1 }, .selectable = true } else null },
    }, 3, cx.allocator);
    const view = try Card.View.mount(cx, scope, .{ .context = state, .on_decision = Preview.decide, .on_route = Preview.chooseRoute });
    state.view = view;
    try view.update(state.broker.snapshot());
    try root.appendChild(cx.allocator, view.root);
    try root.appendChild(cx.allocator, result);
    try cx.addAfterLayoutHook(state, Preview.afterLayout);
    return root;
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--route=ask")) preview_route = true else if (std.mem.eql(u8, arg, "--long-url")) long_url = true else if (std.mem.startsWith(u8, arg, "--kind=")) preview_kind = std.meta.stringToEnum(approval.SubjectKind, arg[7..]) orelse return error.InvalidPreviewKind else if (std.mem.startsWith(u8, arg, "--theme=")) preview_theme = std.meta.stringToEnum(theme.Name, arg[8..]) orelse return error.InvalidPreviewTheme else if (std.mem.startsWith(u8, arg, "--transparency=")) {
            preview_transparency = try std.fmt.parseFloat(f32, arg[15..]);
            if (!std.math.isFinite(preview_transparency) or preview_transparency < 0 or preview_transparency > 100) return error.InvalidPreviewTransparency;
        } else return error.InvalidOption;
    }
    const app = try App.init(std.heap.c_allocator, .{ .io = init.io, .window = .{ .width = 600, .height = 360, .title = "ZeroWork Host Approval Preview", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
