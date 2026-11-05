//! Isolated production recovery card; fabricated receipts, no commands or IO.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const V = @import("ui/ai_recovery_view.zig");
const theme = @import("ui/app_theme.zig");
var fixture: enum { unknown, cooldown, context, verification, verification_stale, verification_legacy } = .unknown;

const Preview = struct {
    cx: *ui.Cx,
    result: *ui.Node,
    verification_record: ?*@import("ai/tool_results.zig").Record = null,
    verification_parent: ?*ui.Node = null,
    reads: usize = 0,
    strip: ?*@import("ui/ai_strip_view.zig").View = null,
    strip_width: f32 = -1,
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Preview = @ptrCast(@alignCast(raw));
        const strip = self.strip orelse return .done;
        const parent = strip.root.parent orelse return .done;
        const width = parent.globalRect().w;
        if (self.strip_width == width) return .done;
        self.strip_width = width;
        strip.update(.{ .x = 0, .y = 0, .w = width, .h = 40 }, true, .unknown, 0, false);
        return .needs_layout;
    }
    fn cleanup(self: *Preview) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn open(self: *Preview) void {
        self.cx.requestRedraw();
    }

    fn verify(raw: *anyopaque, ticket: @import("ui/ai_verification_view.zig").Ticket) void {
        const self: *Preview = @ptrCast(@alignCast(raw));
        const record = self.verification_record orelse return;
        const original = ticket.resolve(record) orelse return;
        if (!original.matches(ticket.turn_id, record.call_id, ticket.arguments_hash)) return;
        const observed = @import("ai/readonly_verification.zig").observe(original, @import("platform/realtime.zig").milliseconds(self), .{ .context = self, .read = read });
        record.targets[0].checks.append(record.arena.allocator(), observed) catch return;
        @import("ui/ai_verification_view.zig").appendObservation(self.cx, self.verification_parent.?, observed) catch return;
        const text = std.fmt.allocPrint(self.cx.allocator, "只读核查 {d} 次 · 原调用 original-call · 原目标 #101 / 3 · 未知状态保留", .{self.reads}) catch return;
        defer self.cx.allocator.free(text);
        self.result.setTextContent(self.cx.allocator, text) catch {};
        self.cx.requestRedraw();
    }
    fn read(raw: *anyopaque, anchor: @import("ai/readonly_verification.zig").Anchor) !@import("ai/readonly_verification.zig").Observation {
        const self: *Preview = @ptrCast(@alignCast(raw));
        self.reads += 1;
        if (fixture == .verification_stale) return error.StaleSession;
        var observed: @import("ai/readonly_verification.zig").Observation = .{ .anchor = anchor, .exit_code = 0, .foreground_finished = true, .local_released = false, .remote_effect_unknown = true };
        observed.copyOutput("original operation output", "");
        return observed;
    }
    fn destroyStore(store: *@import("ai/tool_results.zig").Store) void {
        store.deinit();
    }

    fn enqueue(raw: *anyopaque, envelope: V.Envelope) void {
        const self: *Preview = @ptrCast(@alignCast(raw));
        self.result.setTextContent(self.cx.allocator, switch (envelope.action) {
            .answer => "已请求仅重试答复 · 不执行命令",
            .edit => "已回填问题",
            .regenerate => "已请求新计划",
        }) catch {};
        self.cx.requestRedraw();
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.selectTokens(@import("config/theme_registry.zig").builtinTokens("dark"));
    cx.setTheme(theme.widgetTheme(theme.currentName()));
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = .{ .top = 48, .left = 14, .right = 14 }, .gap = 12, .background = theme.current().surface_1 }, .{});
    const result = try ui.textStyled(cx, @import("ui/ai_recovery_styles.zig").text, "等待恢复操作");
    result.meta.ownership.meta.test_id = "ai.recovery.preview.result";
    const state = try scope.createState(Preview, .{ .cx = cx, .result = result });
    const context_failed = fixture == .context;
    try root.appendChild(cx.allocator, try V.mount(cx, scope, .{
        .ticket = .{ .owner = .{ .session = 101 }, .turn = 77 },
        .title = if (context_failed) "上下文压缩失败" else "请求失败",
        .reason = if (context_failed) "上下文压缩失败，原始上下文、输入和附件已保留" else "部分工具执行结果待核实，已保留收到的内容",
        .detail = if (context_failed) "ContextCompactionFailed" else "请求失败 · ToolOutcomeUnknown",
        .retries = 0,
        .max_retries = 3,
        .has_tool_calls = !context_failed,
        .retry_enabled = fixture == .unknown or fixture == .verification or fixture == .verification_stale or fixture == .verification_legacy,
        .regenerate_enabled = context_failed,
        .retry_disabled_reason = if (context_failed) "仅重试答复不可用：上下文压缩失败，请先修复上下文。" else null,
        .regenerate_disabled_reason = if (!context_failed) "新计划不可用：请先核实结果未知的操作。" else null,
        .cooldown_seconds = if (fixture == .cooldown) 2 else 0,
    }, .{ .context = state, .enqueue = Preview.enqueue }));
    if (fixture == .verification or fixture == .verification_stale or fixture == .verification_legacy) {
        state.strip = try @import("ui/ai_strip_view.zig").View.mount(cx, scope, cx.on(Preview, state, Preview.open));
        try root.appendChild(cx.allocator, state.strip.?.root);
        try cx.addAfterLayoutHook(state, Preview.afterLayout);
        try scope.onCleanup(Preview, state, Preview.cleanup);
        const facts = @import("ai/tool_results.zig");
        const verification = facts.Verification;
        const owner: @import("host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 3 };
        var run = @import("ai/tool_loop.zig").Loop.init(cx.allocator, .{ .owner = .{ .session = 101 }, .members = .{ .ids = .{101} ++ @as([15]u64, @splat(0)), .len = 1 } }, 77, .{});
        defer run.deinit();
        var outcome = try @import("ai/tool_loop.zig").Outcome.copy(cx.allocator, &.{.{ .session_id = 101, .status = .unknown, .transport = .ssh, .remote_effect_unknown = true, .local_released = false }});
        if (fixture != .verification_legacy) outcome.verification = .{ .owner = owner, .operation_key = .{ .owner = .{ .session = owner }, .operation_id = 9 }, .service = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .exec, .binding_id = 7, .binding_generation = 2 }, .turn_id = 77, .call_hash = verification.digest("original-call"), .arguments_hash = verification.digest("original-args") };
        try run.records.append(run.arena.allocator(), .{ .key = .{ .owner = .{ .session = 101 }, .turn_id = 77, .call_id = "original-call" }, .name = "run_command", .arguments = "original-args", .arguments_hash = verification.digest("original-args"), .dispatched = true, .outcome = outcome });
        const store = try scope.createState(facts.Store, facts.Store.init(cx.allocator));
        try scope.onCleanup(facts.Store, store, Preview.destroyStore);
        _ = try store.capture(&run, &.{.{ .owner = owner, .label = "ScaleX40-AI01" }});
        state.verification_record = store.records.items[0];
        const panel = try ui.boxStyled(cx, @import("ui/ai_recovery_styles.zig").root, .{});
        try @import("ui/ai_verification_view.zig").mount(cx, scope, panel, state.verification_record.?, .{ .context = state, .enqueue = Preview.verify });
        state.verification_parent = panel.children.items[0];
        try root.appendChild(cx.allocator, panel);
    }
    try root.appendChild(cx.allocator, result);
    return root;
}
pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    if (args.next()) |arg| fixture = std.meta.stringToEnum(@TypeOf(fixture), arg) orelse return error.InvalidFixture;
    try @import("platform/ui_fonts.zig").register();
    const app = try App.init(std.heap.c_allocator, .{ .io = init.io, .font = .{ .fallback_families = @import("platform/ui_fonts.zig").families }, .window = .{ .width = 600, .height = if (fixture == .verification or fixture == .verification_stale or fixture == .verification_legacy) 640 else @as(f32, 320), .title = "ZeroWork Recovery Preview", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
