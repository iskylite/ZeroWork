//! Isolated production cleanup-row View. Representative immutable resources;
//! real Local lifecycle/retention is covered by application_host tests.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const finish = @import("ui/ai_task_finish.zig");
const theme = @import("ui/app_theme.zig");
const identity = @import("host/identity.zig");
var selected_theme: theme.Name = .dark;
var initial_phase: finish.Phase = .choice;
var long_target = false;
var multi_target = false;
var three_targets = false;
const Preview = struct {
    cx: *ui.Cx,
    view: *finish.View = undefined,
    snapshot: finish.Snapshot,
    resource: finish.Resource,
    targets: [3]finish.InputTarget = undefined,
    result: *ui.Node,
    pending: ?finish.Decision = null,
    pending_control: ?finish.Control = null,
    fn choose(raw: *anyopaque, task: identity.TaskId, revision: u64, decision: finish.Decision) !void {
        const self: *Preview = @ptrCast(@alignCast(raw));
        if (!self.snapshot.context.task_id.eql(task) or self.snapshot.revision != revision) return error.ScopeChanged;
        self.pending = decision;
        self.cx.requestRedraw();
    }
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Preview = @ptrCast(@alignCast(raw));
        if (self.pending_control) |action| {
            self.pending_control = null;
            self.snapshot.revision += 1;
            self.snapshot.phase = .settling;
            self.snapshot.control_pending = true;
            self.snapshot.active_executions = 0;
            self.snapshot.feedback = if (action == .takeover) "接管选择已交付；等待真实输入释放" else "停止选择已交付；等待真实退出证据";
            if (action == .takeover) self.resource.ownership = .handed_to_user;
            self.view.update(self.snapshot) catch {};
            return .needs_layout;
        }
        const decision = self.pending orelse return .done;
        self.pending = null;
        self.snapshot.revision += 1;
        self.snapshot.phase = if (decision == .keep) .kept else .closed;
        if (decision == .close) self.resource.state = .closed;
        self.snapshot.resources = @as(*const [1]finish.Resource, @ptrCast(&self.resource));
        self.view.update(self.snapshot) catch {};
        self.result.setTextContent(self.cx.allocator, if (decision == .keep) "保留选择已交付原控制器" else "关闭选择已交付原控制器") catch {};
        return .needs_layout;
    }
    fn control(raw: *anyopaque, task: identity.TaskId, revision: u64, action: finish.Control) !void {
        const self: *Preview = @ptrCast(@alignCast(raw));
        if (!self.snapshot.context.task_id.eql(task) or self.snapshot.revision != revision) return error.ScopeChanged;
        self.pending_control = action;
        self.cx.requestRedraw();
    }
    fn controlTarget(raw: *anyopaque, task: identity.TaskId, revision: u64, handle: identity.SessionHandle, execution: identity.ExecutionId) !void {
        const self: *Preview = @ptrCast(@alignCast(raw));
        if (!self.snapshot.context.task_id.eql(task) or self.snapshot.revision != revision) return error.ScopeChanged;
        for (self.snapshot.targets) |target| if (target.handle.eql(handle) and target.execution_id.eql(execution)) {
            self.pending_control = .takeover;
            const result = try std.fmt.allocPrint(self.cx.allocator, "精确接管 session-{d}", .{@backingInt(handle.session_id)});
            defer self.cx.allocator.free(result);
            try self.result.setTextContent(self.cx.allocator, result);
            self.cx.requestRedraw();
            return;
        };
        return error.ScopeChanged;
    }
    fn cleanup(self: *Preview) void {
        self.cx.removeAfterLayoutHook(self);
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(selected_theme);
    cx.setTheme(theme.widgetTheme(selected_theme));
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = ui.Padding.all(14), .gap = 12, .background = theme.current().surface_1 }, .{});
    root.meta.ownership.meta.test_id = "task_finish.preview";
    const result = try ui.text(cx, "任务收尾 · 原生组件", .{ .font_size = 11, .color = theme.current().fg_2 });
    result.meta.ownership.meta.test_id = "task_finish.preview.result";
    const state = try scope.createState(Preview, .{ .cx = cx, .snapshot = .{ .context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .group = 3 }, .binding_revision = 1, .grant_revision = 1 }, .revision = 1, .phase = initial_phase, .resources = &.{}, .active_executions = if (initial_phase == .working) 1 else 0, .remote_effect_unknown = initial_phase == .cleanup_pending, .feedback = null, .visible = true }, .resource = .{ .handle = .{ .session_id = @fromBackingInt(6) }, .ownership_revision = 1, .ownership = .created_task, .retention = .ask, .state = .ready, .idle = if (initial_phase == .working) .active else .confirmed }, .result = result });
    const label = if (long_target) "工作终端 · production-session-with-a-long-visible-target-name" else "工作终端 · Local Terminal";
    if (initial_phase == .cleanup_pending) {
        state.resource.state = .cleanup_pending;
        state.resource.idle = .unknown;
    }
    @memcpy(state.resource.name[0..label.len], label);
    state.resource.name_len = label.len;
    state.snapshot.resources = @as(*const [1]finish.Resource, @ptrCast(&state.resource));
    state.snapshot.model_done = false;
    for (&state.targets, 0..) |*target, i| {
        target.* = .{ .handle = .{ .session_id = @fromBackingInt(6 + i) }, .execution_id = .generate() };
        target.setName(if (i == 0) "工作终端 A" else if (i == 1) "工作终端 B" else "工作终端 C");
    }
    if (initial_phase == .working) state.snapshot.targets = state.targets[0..if (three_targets) 3 else if (multi_target) 2 else 1];
    state.view = try finish.View.mount(cx, scope, .{ .context = state, .on_decision = Preview.choose, .on_control = Preview.control, .on_control_target = Preview.controlTarget });
    try state.view.update(state.snapshot);
    try root.appendChild(cx.allocator, state.view.root);
    try root.appendChild(cx.allocator, result);
    try scope.onCleanup(Preview, state, Preview.cleanup);
    try cx.addAfterLayoutHook(state, Preview.tick);
    return root;
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--theme=")) selected_theme = std.meta.stringToEnum(theme.Name, arg[8..]) orelse return error.InvalidTheme else if (std.mem.startsWith(u8, arg, "--state=")) initial_phase = std.meta.stringToEnum(finish.Phase, arg[8..]) orelse return error.InvalidState else if (std.mem.eql(u8, arg, "--long-target")) long_target = true else if (std.mem.eql(u8, arg, "--multi-target")) multi_target = true else if (std.mem.eql(u8, arg, "--three-targets")) three_targets = true else return error.InvalidOption;
    }
    const app = try App.init(std.heap.c_allocator, .{ .io = init.io, .window = .{ .width = 600, .height = 240, .title = "ZeroWork Task Finish Preview", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
