//! Isolated production host execution-result projection and native View.
//! Fixture receipts are serialized using the real host Snapshot; no PTY/network.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const theme = @import("ui/app_theme.zig");
const facts = @import("ai/tool_results.zig");
const terminal = @import("host/terminal_execution.zig");
const identity = @import("host/identity.zig");
const Execution = @import("ui/ai_execution_result_view.zig");
const Fixture = enum { running, sealed, failed, interval_recorded, interval_unverified, interval_concurrent, interval_failed, recording_failed, unknown, handed_off, sealing, cancelled, missing, refused };
var fixture: Fixture = .running;
var preview_theme: theme.Name = .dark;
var transparency: f32 = 0;
var long_output = false;
const Preview = struct {
    cx: *ui.Cx,
    store: facts.Store,
    action: *ui.Node,
    actions: usize = 0,
    fn cleanup(self: *Preview) void {
        self.store.deinit();
    }
    fn perform(raw: *anyopaque, action: Execution.Action, target: facts.ExecutionActionTarget) !void {
        const self: *Preview = @ptrCast(@alignCast(raw));
        self.actions += 1;
        const text = try std.fmt.allocPrint(self.cx.allocator, "{s} · request {d} · {s} · #{d}/g{d}", .{ @tagName(action), self.actions, target.reference(), @backingInt(target.session.session_id), target.session.generation });
        defer self.cx.allocator.free(text);
        try self.action.setTextContent(self.cx.allocator, text);
        self.cx.requestRedraw();
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(preview_theme);
    _ = theme.setMaterialParameters(transparency, 0);
    cx.setTheme(theme.widgetTheme(preview_theme));
    try @import("ui/layer_materials.zig").Policy.mount(cx, scope);
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = .{ .left = 14, .right = 14, .top = 48 }, .background = theme.current().overlay, .gap = 8 }, .{});
    root.meta.ownership.meta.test_id = "execution_result.preview";
    const action = try ui.text(cx, "尚未请求操作", .{ .font_size = 11, .wrap = .word, .color = theme.current().fg_2 });
    action.meta.ownership.meta.test_id = "execution_result.preview.action";
    const preview = try scope.createState(Preview, .{ .cx = cx, .store = facts.Store.init(cx.allocator), .action = action });
    try scope.onCleanup(Preview, preview, Preview.cleanup);
    const context: @import("ai/host_tools.zig").Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .group = 7 }, .binding_revision = 2, .grant_revision = 1 };
    const target: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 9 };
    const exec: identity.ExecutionId = .generate();
    const recording: identity.RecordingId = .generate();
    const reference = try std.fmt.allocPrint(cx.allocator, "x1:{s}", .{std.fmt.bytesToHex(exec.bytes, .lower)});
    defer cx.allocator.free(reference);
    const saved_interval = fixture == .interval_recorded or fixture == .interval_unverified or fixture == .interval_concurrent or fixture == .interval_failed;
    var snapshot: terminal.Snapshot = .{ .owner = target, .execution_id = exec, .state = switch (fixture) {
        .running, .handed_off => .running,
        .sealed, .failed => .sealed,
        .interval_recorded, .interval_unverified, .interval_concurrent, .interval_failed => .interval_recorded,
        .recording_failed => .recording_degraded,
        .unknown, .missing, .refused => .outcome_unknown,
        .sealing => .recording_sealing,
        .cancelled => .cancelled_unsent,
    }, .elapsed_ms = 6789, .recording_id = if (fixture == .cancelled or fixture == .missing) null else std.fmt.bytesToHex(recording.bytes, .lower), .input_handed_off = fixture == .handed_off, .remote_effect_unknown = fixture == .unknown, .recording_settled = fixture == .sealed or fixture == .failed or saved_interval, .output_scope = if (fixture == .sealed or fixture == .failed) .exact else .session_interval, .output_attribution = if (fixture == .interval_concurrent) .concurrent_observed else if (fixture == .interval_recorded or fixture == .interval_failed) .no_concurrent_owner_observed else .unverified, .output_attribution_reason = if (fixture == .interval_unverified) "OutputObservationDeadline" else if (fixture == .interval_concurrent) "BackgroundJobsObserved" else null, .interval_saved = saved_interval, .recording_failed = fixture == .recording_failed };
    if (fixture == .running) snapshot.grant = .{ .execution_id = exec, .task_id = context.task_id, .fence = 8, .input_epoch = 3, .ownership_revision = 2 };
    if (fixture == .sealed or fixture == .failed) snapshot.process = .{ .foreground_finished = true, .exit_code = if (fixture == .failed) 7 else 0 };
    if (saved_interval or fixture == .recording_failed) snapshot.process = .{ .foreground_finished = true, .exit_code = if (fixture == .interval_failed or fixture == .recording_failed) 7 else 0 };
    const output = if (long_output) try std.mem.join(cx.allocator, "\n", &@as([40][]const u8, @splat("ACTUAL_TERMINAL_OUTPUT · selected execution, original spacing and a long line for horizontal scrolling"))) else try cx.allocator.dupe(u8, "Checking release…\nACTUAL_TERMINAL_OUTPUT\nOutput boundary retained.");
    defer cx.allocator.free(output);
    const content = if (fixture == .refused) try cx.allocator.dupe(u8, "{\"error_code\":\"IntegrationUnavailable\",\"side_effect_started\":false,\"local_released\":true,\"remote_effect_unknown\":false}") else if (fixture == .missing) try cx.allocator.dupe(u8, "{\"status\":\"failed\",\"error_code\":\"HostToolGatewayUnavailable\"}") else try std.json.Stringify.valueAlloc(cx.allocator, .{ .execution_ref = reference, .snapshot = snapshot, .recording_ref = if (snapshot.recording_id) |*id| @as([]const u8, id) else null, .output = if (fixture == .cancelled) "" else output, .output_available = fixture != .cancelled, .gap = false, .truncated = long_output, .stop_requested = false }, .{});
    defer cx.allocator.free(content);
    var run = @import("ai/tool_loop.zig").Loop.init(cx.allocator, .{ .owner = context.binding, .members = .{} }, 42, .{});
    defer run.deinit();
    var host_result: ?@import("ai/host_tools.zig").Result = null;
    if (fixture != .missing) {
        const blocks = try cx.allocator.alloc(@import("ai/host_tools.zig").Block, 1);
        blocks[0] = .{ .structured = try cx.allocator.dupe(u8, content) };
        host_result = .{ .status = if (fixture == .refused) .rejected else if (fixture == .cancelled) .cancelled_unsent else .succeeded, .blocks = blocks, .receipt = .{ .conversation_id = context.conversation_id, .task_id = context.task_id, .operation_id = 5, .binding_revision = 2, .remote_effect_unknown = fixture == .unknown } };
    }
    try run.records.append(run.arena.allocator(), .{ .key = .{ .owner = context.binding, .turn_id = 42, .call_id = "execution-result-preview" }, .name = "host.run_in_terminal", .arguments = "{\"command\":\"./deploy/check-release.sh --interactive\"}", .arguments_hash = @splat(1), .dispatched = fixture != .missing and fixture != .cancelled and fixture != .refused, .host_result = host_result, .result_body = if (fixture == .missing) try run.arena.allocator().dupe(u8, content) else null });
    _ = try preview.store.capture(&run, &.{.{ .owner = target, .label = "deploy@app-prod-01.example.net:2222" }});
    const record = preview.store.records.items[0];
    record.expanded = true;
    const card = try Execution.mount(cx, scope, &preview.store, record, .{ .context = preview, .perform = Preview.perform }, null);
    card.meta.ownership.meta.test_id = "execution_result.preview.card";
    try root.appendChild(cx.allocator, card);
    try root.appendChild(cx.allocator, action);
    const expected = try ui.text(cx, if (fixture == .missing or fixture == .refused) "未取得执行引用" else reference, .{ .font_size = 10.5, .color = theme.current().fg_2 });
    expected.meta.ownership.meta.test_id = "execution_result.preview.execution_ref";
    try root.appendChild(cx.allocator, expected);
    return root;
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--theme=")) preview_theme = std.meta.stringToEnum(theme.Name, arg[8..]) orelse return error.InvalidTheme else if (std.mem.startsWith(u8, arg, "--state=")) fixture = std.meta.stringToEnum(Fixture, arg[8..]) orelse return error.InvalidState else if (std.mem.eql(u8, arg, "--long-output")) long_output = true else if (std.mem.startsWith(u8, arg, "--transparency=")) {
            transparency = try std.fmt.parseFloat(f32, arg[15..]);
            if (!std.math.isFinite(transparency) or transparency < 0 or transparency > 100) return error.InvalidTransparency;
        } else return error.InvalidOption;
    }
    const app = try App.init(std.heap.c_allocator, .{ .io = init.io, .window = .{ .width = 600, .height = 420, .title = "ZeroWork Execution Result Preview", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
