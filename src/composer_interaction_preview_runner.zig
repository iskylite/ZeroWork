//! Isolated production composer acceptance. Fabricated requests exercise the
//! real native component and question Broker; no commands/network are executed.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const V = @import("ui/ai_composer_interaction_view.zig");
const Q = @import("ai/user_interaction.zig");
const H = @import("ai/host_tools.zig");
const S = @import("ui/ai_assistant_styles.zig");
const theme = @import("ui/app_theme.zig");
const Controls = @import("ui/ai_composer_controls_view.zig");
var initial: enum { approval, question, pending, baseline, route, long } = .approval;
var selected_theme: []const u8 = "dark";
const Preview = struct {
    cx: *ui.Cx,
    view: *V.View,
    composer: *ui.Node,
    input: ui.widgets.input.TextareaResult,
    controls: *Controls.View,
    transcript: ui.widgets.ScrollAreaResult,
    broker: Q.Broker = .{},
    ticket: ?Q.Ticket = null,
    kind: @TypeOf(initial) = .approval,
    sequence: u64 = 1,
    active: bool = true,
    result: *ui.Node,
    route: @import("ai/execution_routing.zig").Route = .batch,
    fn context() H.Context {
        return .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 101 }, .binding_revision = 1, .grant_revision = 1 };
    }
    fn start(self: *Preview, kind: @TypeOf(initial)) !void {
        self.broker.configure(context());
        self.ticket = null;
        self.kind = kind;
        self.sequence += 1;
        self.active = kind != .baseline;
        if (kind == .question) {
            const json = "{\"question\":\"你希望如何处理 Nginx？\",\"options\":[{\"id\":\"reload\",\"label\":\"平滑重载配置\",\"description\":\"不中断现有连接\"},{\"id\":\"restart\",\"label\":\"重启服务\",\"description\":\"可能短暂中断连接\"}]}";
            const parsed = try std.json.parseFromSlice(std.json.Value, self.cx.allocator, json, .{});
            defer parsed.deinit();
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(json, &hash, .{});
            self.ticket = try self.broker.begin(.{ .context = context(), .authority = .conversation_context, .operation_id = self.sequence, .turn_id = 1, .call_id = "preview-question", .tool_id = Q.contribution.definition.id, .arguments = parsed.value, .arguments_json = json, .arguments_hash = hash, .canonical_arguments_hash = try @import("ai/canonical_arguments.zig").digest(self.cx.allocator, parsed.value) }, self.cx.allocator);
        }
        try self.result.setTextContent(self.cx.allocator, "已检查 Nginx 的运行状态，当前有 23 个活动连接。需要你确认后再继续。");
        self.cx.requestRedraw();
    }
    fn act(raw: *anyopaque, ticket: V.Ticket, action: V.Action) !void {
        const self: *Preview = @ptrCast(@alignCast(raw));
        if (ticket == .question) {
            if (action != .answer) return error.InvalidInteractionAction;
            try self.broker.answer(ticket.question, action.answer.option_id, action.answer.text);
            const answer = (try self.broker.poll(ticket.question)).?;
            try self.result.setTextContent(self.cx.allocator, answer.text.text());
        } else {
            if (ticket.host.sequence != self.sequence) return error.StaleApproval;
            if (action == .route) {
                self.route = action.route;
                self.cx.requestRedraw();
                return;
            }
            try self.result.setTextContent(self.cx.allocator, if (action == .approve) "已允许此操作 · 预览不执行命令" else "已拒绝此操作 · 未执行命令");
        }
        self.active = false;
        self.cx.requestRedraw();
    }
    fn stop(self: *Preview) void {
        self.broker.stop();
        self.active = false;
        self.result.setTextContent(self.cx.allocator, "任务已停止") catch {};
        self.cx.requestRedraw();
    }
    fn approval(self: *Preview) void {
        self.start(.approval) catch {};
    }
    fn ask(self: *Preview) void {
        self.start(.question) catch {};
    }
    fn replace(self: *Preview) void {
        self.start(self.kind) catch {};
    }
    fn control(_: *anyopaque, _: Controls.Envelope) !void {}
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Preview = @ptrCast(@alignCast(raw));
        var options: [6]V.Option = undefined;
        const pending = self.broker.snapshot();
        var snapshot: ?V.Snapshot = null;
        if (self.active) {
            if (pending) |*value| {
                for (value.options[0..value.option_count], 0..) |*option, index| options[index] = .{ .id = option.id.text(), .label = option.label.text(), .description = option.description.text() };
                snapshot = .{ .ticket = .{ .question = value.ticket }, .title = value.question.text(), .options = options[0..value.option_count] };
            } else snapshot = .{ .ticket = .{ .host = .{ .sequence = self.sequence, .hash = @splat(7) } }, .title = "确认重启 Nginx", .target = "prod-web-01", .detail = if (self.kind == .long) "sudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\nsudo systemctl restart nginx\n" else "sudo systemctl restart nginx", .impact = "重启会短暂中断连接。", .route = self.route, .route_selectable = self.kind == .route, .route_reason = if (self.kind == .route) "仅选择此命令的运行方式" else "" };
        }
        const changed = self.view.update(snapshot) catch false;
        if (self.kind == .pending and !self.view.postponed) {
            self.kind = .approval;
            self.view.postponed = true;
        }
        const expanded = self.view.expanded();
        self.controls.setInteraction(expanded);
        self.input.wrapper.setDisplay(if (expanded) .none else .flex);
        const height: f32 = if (expanded) self.view.bodyHeight() + 44 else 90;
        const resized = self.composer.style.height != .px or self.composer.style.height.px != height;
        self.composer.setStyleInline(self.cx.allocator, .{ .height = .{ .px = height } });
        var padding = self.transcript.content.style.padding;
        padding.bottom = if (self.view.pendingVisible()) 32 else 0;
        self.transcript.content.setStyleInline(self.cx.allocator, .{ .padding = padding });
        return if (changed or resized) .needs_layout else .done;
    }
    fn cleanup(self: *Preview) void {
        self.broker.stop();
        self.cx.removeAfterLayoutHook(self);
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.selectTokens(@import("config/theme_registry.zig").builtinTokens(selected_theme));
    cx.setTheme(theme.widgetTheme(theme.currentName()));
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .background = theme.baseColors().app.withAlpha(255) }, .{});
    const fixture_bar = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 40 }, .padding = .{ .left = 88 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 }, .{});
    try root.appendChild(cx.allocator, fixture_bar);
    const panel = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .direction = .column, .background = theme.current().overlay, .border = .{ .radius = 14 } }, .{});
    panel.meta.ownership.meta.test_id = "ai.composer.preview.panel";
    try root.appendChild(cx.allocator, panel);
    const grip_row = try ui.boxStyled(cx, S.gripRow, .{});
    try grip_row.appendChild(cx.allocator, try ui.boxStyled(cx, S.grip, .{}));
    try panel.appendChild(cx.allocator, grip_row);
    const header = try ui.boxStyled(cx, S.header, .{});
    try header.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.sparkles, theme.current().accent, S.regionIcon()));
    try header.appendChild(cx.allocator, try ui.textStyled(cx, S.title, "AI 助手"));
    try header.appendChild(cx.allocator, try ui.spacer(cx));
    try header.appendChild(cx.allocator, try ui.textStyled(cx, S.secondary, "prod-web-01"));
    try panel.appendChild(cx.allocator, header);
    const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
    scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .margin = .{ .bottom = 6 } });
    scroll.container.meta.ownership.meta.test_id = "ai.conversation.viewport";
    scroll.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = 12, .padding = .{ .left = 14, .right = 14 } });
    const user_row = try ui.box(cx, S.messageRow(true), .{});
    const bubble = try ui.box(cx, S.userBubble(572), .{});
    try bubble.appendChild(cx.allocator, try ui.text(cx, "帮我重启一下 prod-web-01 上的 Nginx。", .{ .font_size = 12, .line_height = 1.5, .color = S.userBubbleForeground(), .wrap = .word }));
    try user_row.appendChild(cx.allocator, bubble);
    try scroll.content.appendChild(cx.allocator, user_row);
    const result = try ui.text(cx, "", .{ .font_size = 12, .line_height = 1.5, .color = theme.current().fg_1, .wrap = .word });
    result.meta.ownership.meta.test_id = "ai.composer.preview.result";
    result.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .flex_shrink = 0 });
    try scroll.content.appendChild(cx.allocator, result);
    try panel.appendChild(cx.allocator, scroll.container);
    const composer = try ui.boxStyled(cx, S.composer, .{});
    S.finishComposer(cx, composer);
    composer.setStyleInline(cx.allocator, .{ .position = .relative });
    composer.meta.ownership.meta.test_id = "ai.composer.preview.composer";
    const draft = try scope.createText("先确认当前连接数，超过 100 就暂不重启", .{});
    const input = try ui.widgets.Textarea(.{ .value = draft, .borderless = true, .rows = 1 }).mountResult(scope, cx);
    input.wrapper.setStyleInline(cx.allocator, S.input());
    input.input.setStyleInline(cx.allocator, S.input());
    @import("ui/ai_composer_sizing.zig").configure(input);
    input.input.meta.ownership.meta.test_id = "ai.prompt";
    const state = try scope.createState(Preview, .{ .cx = cx, .view = undefined, .composer = composer, .input = input, .controls = undefined, .transcript = scroll, .result = result });
    try scope.onCleanup(Preview, state, Preview.cleanup);
    state.controls = try Controls.View.mount(cx, scope, .{ .context = state, .action = Preview.control });
    state.view = try V.View.mount(cx, scope, .{ .context = state, .act = Preview.act });
    try composer.appendChild(cx.allocator, state.view.panel);
    try composer.appendChild(cx.allocator, input.wrapper);
    try state.controls.root.insertChildBefore(cx.allocator, state.view.actions, state.controls.root.children.items[0]);
    const stop = try ui.widgets.Button(.{ .a11y_label = "停止任务", .base_style = S.primary(), .on_click = cx.on(Preview, state, Preview.stop) }).mount(scope, cx);
    stop.meta.ownership.meta.test_id = "ai.stop";
    try stop.appendChild(cx.allocator, try ui.boxStyled(cx, S.stopIcon, .{}));
    try state.controls.trailing.appendChild(cx.allocator, stop);
    try state.controls.update(.{ .owner = .{ .session = 101 }, .revision = 1 });
    try composer.appendChild(cx.allocator, state.controls.root);
    try composer.appendChild(cx.allocator, state.view.pending);
    try panel.appendChild(cx.allocator, composer);
    inline for (.{ .{ "审批", "preview.approval", Preview.approval }, .{ "问答", "preview.question", Preview.ask }, .{ "新请求", "preview.replace", Preview.replace } }) |item| {
        const button = try ui.widgets.Button(.{ .label = item[0], .on_click = cx.on(Preview, state, item[2]) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = item[1];
        try fixture_bar.appendChild(cx.allocator, button);
    }
    try state.start(initial);
    try cx.addAfterLayoutHook(state, Preview.tick);
    return root;
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--state=")) initial = std.meta.stringToEnum(@TypeOf(initial), arg[8..]) orelse return error.InvalidState else if (std.mem.startsWith(u8, arg, "--theme=")) selected_theme = arg[8..] else return error.InvalidOption;
    }
    try @import("platform/ui_fonts.zig").register();
    const app = try App.init(std.heap.c_allocator, .{ .io = init.io, .font = .{ .fallback_families = @import("platform/ui_fonts.zig").families }, .window = .{ .width = 600, .height = 496, .title = "ZeroWork Composer Acceptance", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
