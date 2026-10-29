//! Native projection for trusted host PTY execution results. Legacy/plugin cards
//! keep their existing renderer. Actions always carry the original full owner.
const std = @import("std");
const ui = @import("ui");
const facts = @import("../ai/tool_results.zig");
const theme = @import("app_theme.zig");
const S = @import("ai_execution_result_styles.zig");
pub const Action = enum { view_terminal, stop, takeover };
pub const Callbacks = struct {
    context: *anyopaque,
    perform: *const fn (*anyopaque, Action, facts.ExecutionActionTarget) anyerror!void,
};
const State = struct {
    cx: *ui.Cx,
    store: *facts.Store,
    record: *facts.Record,
    callbacks: ?Callbacks,
    on_toggle: ?ui.Handler(void),
    body: *@import("layout_motion.zig").Disclosure,
    footer: *@import("layout_motion.zig").Disclosure,
    feedback: *ui.Node,
    controls_disabled: *ui.Signal(bool),
    expected: ?facts.ExecutionActionTarget,
    fn toggle(self: *State) void {
        self.record.expanded = !self.record.expanded;
        self.body.setExpanded(self.record.expanded);
        self.footer.setExpanded(self.record.expanded);
        if (self.on_toggle) |callback| callback.invoke();
        self.cx.requestRedraw();
    }
    fn perform(self: *State, action: Action) void {
        const callback = self.callbacks orelse return;
        const projection = self.store.executionProjection(self.record) orelse return;
        const target = projection.actionTarget() orelse return;
        const expected = self.expected orelse return;
        if (!target.conversation_id.eql(expected.conversation_id) or !target.task_id.eql(expected.task_id) or !target.session.eql(expected.session) or !target.execution_id.eql(expected.execution_id)) return;
        if (action == .stop and !projection.canStop()) return;
        if (action == .takeover and !projection.canTakeover()) return;
        callback.perform(callback.context, action, target) catch {
            self.feedback.setTextContent(self.cx.allocator, "操作未完成，请核实原执行的最新状态。") catch {};
            self.feedback.setDisplay(.flex);
            return;
        };
        if (action != .view_terminal) self.controls_disabled.set(true);
        self.cx.requestRedraw();
    }
    fn viewTerminal(self: *State) void {
        self.perform(.view_terminal);
    }
    fn stop(self: *State) void {
        self.perform(.stop);
    }
    fn takeover(self: *State) void {
        self.perform(.takeover);
    }
    fn copyCommand(self: *State) void {
        const projection = self.store.executionProjection(self.record) orelse return;
        _ = ui.platform_services.clipboardSetText(self.cx.system_sdk, projection.command orelse return);
    }
    fn copyOutput(self: *State) void {
        const projection = self.store.executionProjection(self.record) orelse return;
        _ = ui.platform_services.clipboardSetText(self.cx.system_sdk, projection.terminal_output);
    }
    fn copyRecording(self: *State) void {
        const projection = self.store.executionProjection(self.record) orelse return;
        const id = projection.recording_id orelse return;
        const text = std.fmt.bytesToHex(id.bytes, .lower);
        _ = ui.platform_services.clipboardSetText(self.cx.system_sdk, &text);
    }
};

pub fn mount(cx: *ui.Cx, scope: *ui.Scope, store: *facts.Store, record: *facts.Record, callbacks: ?Callbacks, on_toggle: ?ui.Handler(void)) !*ui.Node {
    const projection = store.executionProjection(record) orelse return error.NotExecutionResult;
    const positions = try @import("ai_card_scroll.zig").Keeper.mount(cx, scope, try record.scrollPositions(cx.allocator));
    if (!record.execution_view_initialized) {
        record.execution_view_initialized = true;
        if (facts.execution_projection.isRun(record.name)) record.expanded = true;
    }
    const root = try ui.boxStyled(cx, S.card, .{});
    root.meta.ownership.meta.test_id = record.testId();
    root.meta.ownership.meta.component_name = "HostExecutionResult";
    const header = try ui.widgets.Button(.{ .label = "", .variant = .ghost, .a11y_label = "展开或收起交互式执行记录", .base_style = S.headerButton() }).mount(scope, cx);
    header.setStyleInline(cx.allocator, S.header(cx.tokens));
    header.meta.ownership.meta.test_id = "ai.execution.result.header";
    for (header.children.items) |child| child.setDisplay(.none);
    try root.appendChild(cx.allocator, header);
    const slot = try ui.box(cx, .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .direction = .row, .align_items = .center, .justify = .center, .flex_shrink = 0 }, .{});
    const uncertain = projection.remote_effect_unknown or projection.state == .outcome_unknown or projection.call_status == .outcome_unknown or (projection.input_result and projection.input_receipt != null and projection.input_receipt.?.stage == .outcome_unknown) or (projection.state == null and projection.call_status == .succeeded and (!projection.input_result or projection.input_receipt == null));
    const finished = if (projection.input_result) projection.call_status == .succeeded and !uncertain and projection.input_receipt != null and projection.input_receipt.?.stage == .consumed else (projection.sealed() or projection.intervalRecorded()) and projection.process.?.exit_code == 0 and projection.process.?.signal == null;
    const process_failed = projection.process != null and (projection.process.?.signal != null or (projection.process.?.exit_code != null and projection.process.?.exit_code.? != 0));
    const icon = try ui.iconTint(cx, if (uncertain) ui.icons.get("circle-help").? else if (finished) ui.icons.check else if (projection.call_status == .rejected or projection.call_status == .failed or projection.recording_failed or process_failed) ui.icons.get("circle-alert").? else if (projection.state == .cancelled_unsent or projection.call_status == .cancelled_unsent) ui.icons.get("square").? else ui.icons.terminal, if (process_failed) theme.current().danger_ink else if (uncertain or projection.recording_failed) theme.current().warn_ink else if (finished) theme.current().ok_ink else theme.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 });
    icon.meta.ownership.meta.test_id = "ai.execution.result.icon";
    try slot.appendChild(cx.allocator, icon);
    try header.appendChild(cx.allocator, slot);
    const title = try ui.textStyled(cx, S.title, @import("ai_tool_titles.zig").title(record.name) orelse "执行命令");
    title.meta.ownership.meta.test_id = "ai.execution.result.title";
    title.setStyleInline(cx.allocator, .{ .width = .{ .px = 84 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
    try header.appendChild(cx.allocator, title);
    const observed_status = try std.fmt.allocPrint(cx.allocator, "{s} · {s}", .{ if (projection.input_result) "输入结果" else "最近观测", projection.statusLabel() });
    defer cx.allocator.free(observed_status);
    const summary = try ui.textStyled(cx, S.summary, observed_status);
    if (header.behavior.interaction.a11y) |*attrs| attrs.label = (try scope.createText(observed_status, .{})).peek();
    summary.meta.ownership.meta.test_id = "ai.execution.result.summary";
    summary.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 16 }, .flex = 1, .min_width = 0, .overflow = .hidden });
    try header.appendChild(cx.allocator, summary);
    var elapsed_buffer: [32]u8 = undefined;
    const elapsed = if (projection.elapsed_ms) |ms| if (ms < 1000) try std.fmt.bufPrint(&elapsed_buffer, "{d}ms", .{ms}) else try std.fmt.bufPrint(&elapsed_buffer, "{d:.1}s", .{@as(f64, @floatFromInt(ms)) / 1000}) else "—";
    const clock = try ui.textStyled(cx, S.identity, elapsed);
    clock.meta.ownership.meta.test_id = "ai.execution.result.elapsed";
    clock.setStyleInline(cx.allocator, .{ .width = .{ .px = 44 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
    try header.appendChild(cx.allocator, clock);
    const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
    @import("ai_card_scroll.zig").containVertical(scroll);
    positions.bind(.body, scroll);
    scroll.container.setStyleInline(cx.allocator, S.body(cx.tokens));
    scroll.container.meta.ownership.meta.test_id = "ai.execution.result.details";
    scroll.content.setStyleInline(cx.allocator, S.content(cx.tokens));
    const body_disclosure = try @import("layout_motion.zig").Disclosure.mount(cx, scope, scroll.container, record.expanded);
    try root.appendChild(cx.allocator, body_disclosure.root);
    if (projection.input_result) {
        if (projection.input_receipt) |receipt| {
            const input_type = try ui.textStyled(cx, S.text, switch (receipt.kind) {
                .text => "输入类型 · 文本",
                .enter => "输入类型 · Enter",
                .host_secret => "输入类型 · 宿主安全输入",
            });
            input_type.meta.ownership.meta.test_id = "ai.execution.result.input_type";
            try scroll.content.appendChild(cx.allocator, input_type);
            const sequence = try std.fmt.allocPrint(cx.allocator, "输入序号 {d} · 等待序号 {d}", .{ receipt.input_sequence, receipt.wait_sequence });
            defer cx.allocator.free(sequence);
            const input_sequence = try ui.textStyled(cx, S.metadata, sequence);
            input_sequence.meta.ownership.meta.test_id = "ai.execution.result.input_sequence";
            try scroll.content.appendChild(cx.allocator, input_sequence);
        }
        const input_limit = try ui.textStyled(cx, S.metadata, "此处仅确认本次输入的处理状态；命令执行结果请查看执行记录。");
        input_limit.meta.ownership.meta.test_id = "ai.execution.result.input_limit";
        input_limit.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        try scroll.content.appendChild(cx.allocator, input_limit);
    } else {
        const target = if (projection.target) |owner| try std.fmt.allocPrint(cx.allocator, "目标 · {s}{s}会话 #{d}", .{ projection.target_label, if (projection.target_label.len == 0) "" else " · ", @backingInt(owner.session_id) }) else try cx.allocator.dupe(u8, "目标身份未返回");
        defer cx.allocator.free(target);
        const target_node = try ui.textStyled(cx, S.text, target);
        target_node.meta.ownership.meta.test_id = "ai.execution.result.target";
        target_node.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        try scroll.content.appendChild(cx.allocator, target_node);
    }
    if (projection.failure) |code| {
        const reason = try ui.textStyled(cx, S.text, failureLabel(code));
        reason.meta.ownership.meta.test_id = "ai.execution.result.failure";
        reason.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        try scroll.content.appendChild(cx.allocator, reason);
    }
    if (projection.stop_requested or projection.input_handed_off or projection.recording_failed) {
        const effect = try ui.textStyled(cx, S.text, if (projection.recording_failed) "终端记录保存未确认，仍需核实原终端与执行结果。" else if (projection.input_handed_off) "输入权已交给用户；当前命令与输出观察可继续。" else "已请求停止；尚未确认前台结束或输入权释放。");
        effect.meta.ownership.meta.test_id = "ai.execution.result.effect";
        effect.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        try scroll.content.appendChild(cx.allocator, effect);
    }
    if (projection.process) |process| {
        var process_buffer: [128]u8 = undefined;
        const process_text = if (process.exit_code) |code| try std.fmt.bufPrint(&process_buffer, "{s}退出码 {d}{s}", .{ if (projection.output_scope == .session_interval and process.foreground_finished) "前台已结束 · " else "", code, if (process.background_jobs or process.background_jobs_unknown) " · 后台任务仍需核实" else "" }) else if (process.signal) |signal| try std.fmt.bufPrint(&process_buffer, "{s}结束信号 {d}", .{ if (projection.output_scope == .session_interval and process.foreground_finished) "前台已结束 · " else "", signal }) else if (process.foreground_finished) "前台已结束 · 未提供退出码" else "前台尚未确认结束";
        const process_node = try ui.textStyled(cx, S.metadata, process_text);
        process_node.meta.ownership.meta.test_id = "ai.execution.result.process";
        try scroll.content.appendChild(cx.allocator, process_node);
    }
    if (projection.output_scope == .session_interval) {
        const range = try ui.textStyled(cx, S.metadata, if (projection.intervalRecorded()) "同一终端观测片段 · 已保存" else if (projection.recording_failed) "同一终端观测片段 · 保存失败" else "同一终端观测片段 · 保存待确认");
        range.meta.ownership.meta.test_id = "ai.execution.result.output_scope";
        range.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        try scroll.content.appendChild(cx.allocator, range);
        const attribution = try ui.textStyled(cx, S.metadata, projection.attributionLabel());
        attribution.meta.ownership.meta.test_id = "ai.execution.result.output_attribution";
        attribution.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        try scroll.content.appendChild(cx.allocator, attribution);
        if (projection.output_attribution_reason) |code| {
            const reason = try ui.textStyled(cx, S.metadata, attributionReason(code));
            reason.meta.ownership.meta.test_id = "ai.execution.result.output_attribution_reason";
            reason.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
            try scroll.content.appendChild(cx.allocator, reason);
        }
        const limit = try ui.textStyled(cx, S.metadata, "该片段仅覆盖本次观测区间；其他程序可写入同一终端，后台输出可能在前台结束后继续。");
        limit.meta.ownership.meta.test_id = "ai.execution.result.output_limit";
        limit.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        try scroll.content.appendChild(cx.allocator, limit);
    }
    var command_row: ?*ui.Node = null;
    if (projection.command) |command| {
        const row = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .align_items = .center, .gap = 6, .min_width = 0, .flex_shrink = 0 }, .{});
        command_row = row;
        try scroll.content.appendChild(cx.allocator, row);
        const viewport = try appendOutput(cx, scope, row, command, "ai.execution.result.command", positions);
        viewport.setStyleInline(cx.allocator, .{ .flex = 1, .min_width = 0 });
    }
    if (projection.execution_id) |id| {
        const identity_text = try std.fmt.allocPrint(cx.allocator, "执行 · x1:{s}", .{std.fmt.bytesToHex(id.bytes, .lower)});
        defer cx.allocator.free(identity_text);
        const identity_node = try ui.textStyled(cx, S.identity, identity_text);
        identity_node.meta.ownership.meta.test_id = "ai.execution.result.execution_id";
        identity_node.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        try scroll.content.appendChild(cx.allocator, identity_node);
    }
    if (!projection.input_result) {
        const output_label = try ui.textStyled(cx, S.metadata, if (projection.output_scope == .session_interval) if (projection.terminal_output.len != 0) "同一终端观测片段" else if (projection.output_available) "观测区间暂无输出" else "暂未取得观测片段" else if (projection.terminal_output.len != 0) "终端输出" else if (projection.output_available) "终端暂无输出" else "暂未取得终端输出");
        output_label.meta.ownership.meta.test_id = "ai.execution.result.output_label";
        try scroll.content.appendChild(cx.allocator, output_label);
    }
    if (projection.terminal_output.len != 0) _ = try appendOutput(cx, scope, scroll.content, projection.terminal_output, "ai.execution.result.terminal_output", positions);
    if (projection.output_gap or projection.output_truncated) {
        const note = try ui.textStyled(cx, S.metadata, if (projection.output_gap) "部分输出不在本次返回范围内；可查看原终端记录。" else if (projection.output_scope == .session_interval) "本次返回的观测片段已截断；可查看原终端记录。" else "本次输出已截断；完整内容请查看原终端记录。");
        note.meta.ownership.meta.test_id = "ai.execution.result.output_notice";
        note.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        try scroll.content.appendChild(cx.allocator, note);
    }
    const footer = try ui.boxStyled(cx, S.footer, .{});
    footer.meta.ownership.meta.test_id = "ai.execution.result.footer";
    const footer_disclosure = try @import("layout_motion.zig").Disclosure.mount(cx, scope, footer, record.expanded);
    try root.appendChild(cx.allocator, footer_disclosure.root);
    const feedback = try ui.textStyled(cx, S.text, "");
    feedback.meta.ownership.meta.test_id = "ai.execution.result.action_feedback";
    feedback.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
    feedback.setDisplay(.none);
    try footer.appendChild(cx.allocator, feedback);
    const state = try scope.createState(State, .{ .cx = cx, .store = store, .record = record, .callbacks = callbacks, .on_toggle = on_toggle, .body = body_disclosure, .footer = footer_disclosure, .feedback = feedback, .controls_disabled = try scope.createSignal(bool, callbacks == null), .expected = projection.actionTarget() });
    _ = ui.clickable(header, cx.on(State, state, State.toggle));
    if (command_row) |row| {
        const copy = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.copy, .icon_size = @as(f32, 14), .a11y_label = "复制实际命令", .base_style = S.iconButton(), .on_click = cx.on(State, state, State.copyCommand) }).mount(scope, cx);
        copy.meta.ownership.meta.test_id = "ai.execution.result.copy_command";
        try row.appendChild(cx.allocator, copy);
    }
    if (projection.recording_id) |id| {
        const row = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 }, .{});
        const recording = try std.fmt.allocPrint(cx.allocator, "记录 · {s}", .{std.fmt.bytesToHex(id.bytes, .lower)});
        defer cx.allocator.free(recording);
        const text = try ui.textStyled(cx, S.identity, recording);
        text.meta.ownership.meta.test_id = "ai.execution.result.recording_id";
        text.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex = 1, .flex_shrink = 0 });
        try row.appendChild(cx.allocator, text);
        const copy = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.copy, .icon_size = @as(f32, 14), .a11y_label = "复制真实记录 ID", .base_style = S.iconButton(), .on_click = cx.on(State, state, State.copyRecording) }).mount(scope, cx);
        copy.meta.ownership.meta.test_id = "ai.execution.result.copy_recording";
        try row.appendChild(cx.allocator, copy);
        try scroll.content.appendChild(cx.allocator, row);
    }
    if (projection.actionTarget() != null) {
        const view = try ui.widgets.Button(.{ .variant = .ghost, .label = "查看终端", .base_style = S.action(), .disabled = callbacks == null, .on_click = cx.on(State, state, State.viewTerminal) }).mount(scope, cx);
        view.meta.ownership.meta.test_id = "ai.execution.result.view_terminal";
        try footer.appendChild(cx.allocator, view);
        if (projection.canStop()) {
            const stop = try ui.widgets.Button(.{ .variant = .ghost, .label = "停止执行", .base_style = S.action(), .disabled = state.controls_disabled, .on_click = cx.on(State, state, State.stop) }).mount(scope, cx);
            stop.meta.ownership.meta.test_id = "ai.execution.result.stop";
            try footer.appendChild(cx.allocator, stop);
        }
        if (projection.canTakeover()) {
            const takeover = try ui.widgets.Button(.{ .variant = .ghost, .label = "接管输入", .base_style = S.action(), .disabled = state.controls_disabled, .on_click = cx.on(State, state, State.takeover) }).mount(scope, cx);
            takeover.meta.ownership.meta.test_id = "ai.execution.result.takeover";
            try footer.appendChild(cx.allocator, takeover);
        }
    }
    if (projection.terminal_output.len != 0) {
        const copy = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.copy, .icon_size = @as(f32, 14), .a11y_label = if (projection.output_scope == .session_interval) "复制本次观测片段" else "复制本次终端输出", .base_style = S.iconButton(), .on_click = cx.on(State, state, State.copyOutput) }).mount(scope, cx);
        copy.meta.ownership.meta.test_id = "ai.execution.result.copy_output";
        try footer.appendChild(cx.allocator, copy);
    }
    if (projection.actionTarget() == null and projection.terminal_output.len == 0) footer.setDisplay(.none);
    return root;
}
fn appendOutput(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, bytes: []const u8, id: []const u8, positions: *@import("ai_card_scroll.zig").Keeper) !*ui.Node {
    const scroll = try ui.widgets.ScrollArea(.{ .direction = .horizontal, .rubber_band_x = false }).mount(scope, cx);
    positions.bind(if (std.mem.eql(u8, id, "ai.execution.result.command")) .command else .stdout, scroll);
    scroll.container.setStyleInline(cx.allocator, S.output(cx.tokens));
    const lines = 1 + std.mem.count(u8, std.mem.trimEnd(u8, bytes, "\r\n"), "\n");
    scroll.container.setStyleInline(cx.allocator, .{ .height = .{ .px = @as(f32, @floatFromInt(lines)) * 16 + 8 } });
    scroll.content.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} }, .padding = ui.Padding.all(4), .direction = .column, .flex_shrink = 0 });
    const text = try ui.textStyled(cx, S.mono, bytes);
    text.setStyleInline(cx.allocator, .{ .width = .{ .px = @import("ai_message_view.zig").textWidth(cx, bytes, 11, 400) }, .flex_shrink = 0 });
    text.meta.ownership.meta.test_id = id;
    try scroll.content.appendChild(cx.allocator, text);
    try parent.appendChild(cx.allocator, scroll.container);
    return scroll.container;
}

fn failureLabel(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "IntegrationUnavailable")) return "当前终端的执行能力不可用。";
    if (std.mem.eql(u8, code, "HostToolGatewayUnavailable")) return "宿主执行服务当前不可用。";
    if (std.mem.eql(u8, code, "ToolApprovalRejected")) return "本次调用未获批准。";
    if (std.mem.eql(u8, code, "CancelledBeforeDispatch")) return "派发前已取消，命令未执行。";
    if (std.mem.eql(u8, code, "PermissionDenied") or std.mem.eql(u8, code, "ToolExecutionDenied")) return "当前执行权限不足。";
    if (std.mem.eql(u8, code, "TargetUnavailable") or std.mem.eql(u8, code, "StaleSession") or std.mem.eql(u8, code, "StaleReference")) return "原目标会话已不可用。";
    if (std.mem.eql(u8, code, "TerminalBusy")) return "目标终端正忙。";
    if (std.mem.eql(u8, code, "ExecutionSuperseded")) return "终端已开始其他执行，请核实原命令结果。";
    if (std.mem.eql(u8, code, "InvalidHostToolResult")) return "宿主执行信息未通过校验，结果仍需核实。";
    if (std.mem.eql(u8, code, "UnsupportedInteraction")) return "当前前台交互不受支持，可在原终端查看并接管。";
    return "本次调用未能完成，请核实原终端状态。";
}

fn attributionReason(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "BackgroundJobsObserved")) return "检测到后台任务。";
    if (std.mem.eql(u8, code, "OutputProcessIdentityUnknown")) return "无法确认同一终端中的其他进程身份。";
    if (std.mem.eql(u8, code, "OutputDescriptorsUnknown") or std.mem.eql(u8, code, "OutputDescriptorIdentityUnknown")) return "无法完整观察其他输出来源。";
    if (std.mem.eql(u8, code, "OutputObservationDeadline")) return "并发观察未在时限内完成。";
    if (std.mem.eql(u8, code, "BackgroundJobsUnknown")) return "无法完整确认后台任务。";
    return "宿主未能确认输出来源。";
}
