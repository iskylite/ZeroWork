//! Actual immutable tool facts, never the model's interpretation of an exec.
const std = @import("std");
const ui = @import("ui");
const facts = @import("../ai/tool_results.zig");
const scope_mod = @import("../ai/tool_scope.zig");
const S = @import("ai_tool_results_styles.zig");
pub fn appendForOwner(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, store: *facts.Store, owner: scope_mod.Owner) !void {
    return appendForOwnerWithToggle(cx, scope, parent, store, owner, null);
}
pub fn appendForOwnerWithToggle(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, store: *facts.Store, owner: scope_mod.Owner, on_toggle: ?ui.Handler(void)) !void {
    return appendForOwnerWithImages(cx, scope, parent, store, owner, on_toggle, null);
}
pub fn appendForOwnerWithImages(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, store: *facts.Store, owner: scope_mod.Owner, on_toggle: ?ui.Handler(void), app: ?*@import("zenit_app").App) !void {
    if (store.countForOwner(owner) == 0) return;
    const root = try ui.boxStyled(cx, S.list, .{});
    root.meta.ownership.meta.test_id = "ai.tool.results";
    for (store.records.items) |record| if (record.owner.eql(owner)) {
        if (record.execution != null) {
            try root.appendChild(cx.allocator, try @import("ai_execution_result_view.zig").mount(cx, scope, store, record, null, on_toggle));
            continue;
        }
        const state = try State.mount(cx, scope, record);
        for (record.images) |reference| try state.appendImage(reference, app);
        state.on_toggle = on_toggle;
        try root.appendChild(cx.allocator, state.root);
    };
    try parent.appendChild(cx.allocator, root);
}
pub const State = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    record: *facts.Record,
    on_toggle: ?ui.Handler(void) = null,
    root: *ui.Node,
    body: *ui.Node,
    body_disclosure: *@import("layout_motion.zig").Disclosure = undefined,
    footer_disclosure: *@import("layout_motion.zig").Disclosure = undefined,
    image_content: ?*ui.Node = null,
    footer: *ui.Node,
    identity: *ui.Node,
    metadata: *ui.Node,
    stdout: *ui.Node,
    stderr: *ui.Node,
    feedback: *ui.Node,
    stdout_label: ?*ui.Node = null,
    stderr_label: ?*ui.Node = null,
    stdout_viewport: ?*ui.Node = null,
    stderr_viewport: ?*ui.Node = null,
    copy_stdout_button: ?*ui.Node = null,
    copy_stderr_button: ?*ui.Node = null,
    stdout_scroll: *ui.widgets.scroll_area.ScrollState,
    stderr_scroll: *ui.widgets.scroll_area.ScrollState,
    status_icon: ?*ui.Node = null,
    disclosure_icon: ?*ui.Node = null,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, record: *facts.Record) !*State {
        const self = try scope.createState(State, .{ .cx = cx, .scope = scope, .record = record, .root = undefined, .body = undefined, .footer = undefined, .identity = undefined, .metadata = undefined, .stdout = undefined, .stderr = undefined, .feedback = undefined, .stdout_scroll = undefined, .stderr_scroll = undefined });
        self.root = try ui.boxStyled(cx, S.card, .{});
        self.root.meta.ownership.meta.test_id = record.testId();
        const header = try ui.widgets.Button(.{ .label = "", .variant = .ghost, .a11y_label = "展开或收起步骤", .base_style = S.headerButton() }).mount(scope, cx);
        header.setStyleInline(cx.allocator, S.header(cx.tokens));
        for (header.children.items) |child| child.setDisplay(.none);
        try self.root.appendChild(cx.allocator, header);
        const disclosure = try ui.box(cx, .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .flex_shrink = 0 }, .{});
        disclosure.meta.ownership.meta.test_id = "ai.tool.result.disclosure";
        var all_succeeded = record.targets.len > 0;
        var unknown = record.error_status == .unknown;
        var cancelled = record.error_status == .cancelled or record.error_status == .timed_out;
        for (record.targets) |target| {
            all_succeeded = all_succeeded and target.result.status == .succeeded;
            unknown = unknown or target.result.remote_effect_unknown or target.result.status == .unknown or !target.result.local_released;
            cancelled = cancelled or target.result.status == .cancelled or target.result.status == .timed_out;
        }
        if (record.host) |fact| {
            all_succeeded = fact.status == .succeeded;
            unknown = fact.status == .outcome_unknown or fact.receipt.remote_effect_unknown or !fact.receipt.local_released;
            cancelled = fact.status == .cancelled_unsent;
        }
        const palette = @import("app_theme.zig").current();
        header.meta.ownership.meta.test_id = "ai.tool.result.header";
        self.status_icon = try ui.iconTint(cx, if (unknown) ui.icons.get("circle-help").? else if (all_succeeded) ui.icons.check else if (cancelled) ui.icons.get("square").? else ui.icons.get("circle-alert").?, if (unknown) palette.warn else if (all_succeeded) palette.ok else palette.fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 });
        self.disclosure_icon = try ui.iconTint(cx, ui.icons.chevron_down, palette.fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 });
        self.status_icon.?.meta.ownership.meta.test_id = "ai.tool.result.icon";
        self.disclosure_icon.?.setOpacityRaw(0);
        self.status_icon.?.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 4 }, .top = .{ .px = 4 } } });
        self.disclosure_icon.?.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 4 }, .top = .{ .px = 4 } } });
        try disclosure.appendChild(cx.allocator, self.status_icon.?);
        try disclosure.appendChild(cx.allocator, self.disclosure_icon.?);
        const hovered = try ui.hooks.useHover(scope, header);
        const focused = try ui.hooks.useFocusState(scope, cx, header);
        try scope.createEffect(.{ .hovered = hovered, .focused = focused.visible, .state = self }, struct {
            fn run(ctx: anytype) void {
                if (ctx.hovered.get() or ctx.focused.get()) ctx.state.hoverDisclosure() else ctx.state.leaveDisclosure();
            }
        }.run);
        try header.appendChild(cx.allocator, disclosure);
        const title = try ui.textStyled(cx, S.title, toolTitle(record.name));
        title.setStyleInline(cx.allocator, S.headerTitle(cx.tokens));
        title.meta.ownership.meta.test_id = "ai.tool.result.title";
        try header.appendChild(cx.allocator, title);
        var summary: [256]u8 = undefined;
        const projection = if (record.decision) |approved| std.fmt.bufPrint(&summary, "{s} · {s}", .{ if (approved) "已批准" else "已拒绝", record.command }) catch record.command else record.command;
        const status = try ui.text(cx, projection, .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = palette.fg_2, .text_overflow = .ellipsis });
        status.setStyleInline(cx.allocator, S.headerSummary(cx.tokens));
        status.meta.ownership.meta.test_id = "ai.tool.result.status";
        try header.appendChild(cx.allocator, status);
        var elapsed_ms: u64 = 0;
        for (record.targets) |target| elapsed_ms +|= target.result.elapsed_ms;
        elapsed_ms = record.total_elapsed_ms orelse elapsed_ms;
        var elapsed_buf: [32]u8 = undefined;
        const elapsed = if (elapsed_ms == 0) "—" else if (elapsed_ms < 1000) try std.fmt.bufPrint(&elapsed_buf, "{d}ms", .{elapsed_ms}) else try std.fmt.bufPrint(&elapsed_buf, "{d:.1}s", .{@as(f64, @floatFromInt(elapsed_ms)) / 1000});
        const elapsed_node = try ui.textStyled(cx, S.elapsed, elapsed);
        elapsed_node.setStyleInline(cx.allocator, S.elapsedSlot(cx.tokens));
        elapsed_node.meta.ownership.meta.test_id = "ai.tool.result.elapsed";
        try header.appendChild(cx.allocator, elapsed_node);
        const body = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
        self.body = body.container;
        self.body.setStyleInline(cx.allocator, S.body(cx.tokens));
        self.body.meta.ownership.meta.test_id = "ai.tool.result.details";
        body.content.setStyleInline(cx.allocator, S.content(cx.tokens));
        self.image_content = body.content;
        self.body_disclosure = try @import("layout_motion.zig").Disclosure.mount(cx, scope, self.body, record.expanded);
        try self.root.appendChild(cx.allocator, self.body_disclosure.root);
        const command_row = try ui.boxStyled(cx, S.commandRow, .{});
        const command_lines = 1 + std.mem.count(u8, std.mem.trimEnd(u8, record.command, "\r\n"), "\n");
        const command_height = @max(@as(f32, 27), @as(f32, @floatFromInt(command_lines)) * 16 + 8);
        command_row.setStyleInline(cx.allocator, .{ .height = .{ .px = command_height } });
        try body.content.appendChild(cx.allocator, command_row);
        const command_scroll = try ui.widgets.ScrollArea(.{ .direction = .both, .height = 27, .rubber_band_x = false }).mount(scope, cx);
        command_scroll.container.setStyleInline(cx.allocator, S.commandViewport(cx.tokens));
        command_scroll.container.setStyleInline(cx.allocator, .{ .height = .{ .px = command_height } });
        command_scroll.content.setStyleInline(cx.allocator, S.outputContent(cx.tokens));
        const command = try ui.textStyled(cx, S.multilineOutput, record.command);
        command.setStyleInline(cx.allocator, .{ .width = .{ .px = @import("ai_message_view.zig").textWidth(cx, record.command, 11, 400) }, .flex_shrink = 0 });
        command.meta.ownership.meta.test_id = "ai.tool.result.command";
        try command_scroll.content.appendChild(cx.allocator, command);
        try command_row.appendChild(cx.allocator, command_scroll.container);
        const legacy = @import("../ai/plugin_tools.zig").legacyName(record.name);
        const copy_command = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.copy, .icon_size = @as(f32, 14), .a11y_label = if (legacy) "复制原始完整命令或路径" else "复制调用参数", .base_style = S.button(22), .on_click = cx.on(State, self, copyCommand) }).mount(scope, cx);
        copy_command.meta.ownership.meta.test_id = "ai.tool.result.copy_command";
        try command_row.appendChild(cx.allocator, copy_command);
        for (record.targets, 0..) |target, index| {
            const row = try scope.createState(Row, .{ .view = self, .index = index });
            var status_buf: [256]u8 = undefined;
            const label = try std.fmt.allocPrint(cx.allocator, "#{d} · {s} · {s}", .{ target.result.session_id, target.label, targetStatus(target.result, &status_buf) });
            row.label = label;
            try scope.onCleanup(Row, row, Row.cleanup);
            const button = try ui.widgets.Button(.{ .label = "", .variant = .ghost, .a11y_label = label, .base_style = S.targetButton(), .on_click = cx.on(Row, row, Row.select) }).mount(scope, cx);
            const id = try std.fmt.bufPrint(&row.test_id, "ai.tool.result.target.{d}", .{target.result.session_id});
            button.meta.ownership.meta.test_id = id;
            // Keep native Button focus/key/click behavior, while laying out
            // its content using the exact Figma 16/186/6/fill target slots.
            for (button.children.items) |child| child.setDisplay(.none);
            button.setStyleInline(cx.allocator, .{ .justify = .start });
            const contents = try ui.boxStyled(cx, S.targetRow, .{});
            try contents.appendChild(cx.allocator, try ui.iconTint(cx, if (target.result.transport == .local) ui.icons.terminal else ui.icons.server, @import("app_theme.zig").current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 }));
            const name = try std.fmt.allocPrint(cx.allocator, "#{d} · {s}", .{ target.result.session_id, target.label });
            defer cx.allocator.free(name);
            const member_label = try ui.textStyled(cx, S.targetText, name);
            member_label.setStyleInline(cx.allocator, S.targetLabel(cx.tokens));
            try contents.appendChild(cx.allocator, member_label);
            try contents.appendChild(cx.allocator, try ui.box(cx, .{ .width = .{ .px = 6 }, .height = .{ .px = 1 }, .flex_shrink = 0 }, .{}));
            const member_status = try ui.textStyled(cx, S.targetText, targetStatus(target.result, &status_buf));
            member_status.setStyleInline(cx.allocator, S.targetStatus(cx.tokens));
            try contents.appendChild(cx.allocator, member_status);
            try button.appendChild(cx.allocator, contents);
            try body.content.appendChild(cx.allocator, button);
        }
        self.identity = try ui.textStyled(cx, S.text, "");
        self.identity.meta.ownership.meta.test_id = "ai.tool.result.identity";
        try body.content.appendChild(cx.allocator, self.identity);
        self.metadata = try ui.textStyled(cx, S.text, "");
        self.metadata.meta.ownership.meta.test_id = "ai.tool.result.metadata";
        try body.content.appendChild(cx.allocator, self.metadata);
        self.stdout_label = try ui.textStyled(cx, S.text, if (legacy) "标准输出" else "结果内容");
        self.stdout_label.?.meta.ownership.meta.test_id = "ai.tool.result.output_label";
        try body.content.appendChild(cx.allocator, self.stdout_label.?);
        const stdout = try ui.widgets.ScrollArea(.{ .direction = .horizontal, .rubber_band_x = false }).mount(scope, cx);
        self.stdout_scroll = stdout.state;
        self.stdout_viewport = stdout.container;
        stdout.container.setStyleInline(cx.allocator, S.outputViewport(cx.tokens));
        stdout.container.meta.ownership.meta.test_id = "ai.tool.result.stdout_scroll";
        stdout.content.setStyleInline(cx.allocator, S.outputContent(cx.tokens));
        try body.content.appendChild(cx.allocator, stdout.container);
        self.stdout = try ui.textStyled(cx, S.multilineOutput, "");
        self.stdout.meta.ownership.meta.test_id = "ai.tool.result.stdout";
        try stdout.content.appendChild(cx.allocator, self.stdout);
        self.stderr_label = try ui.textStyled(cx, S.text, if (legacy) "错误输出" else "错误详情");
        self.stderr_label.?.meta.ownership.meta.test_id = "ai.tool.result.error_label";
        try body.content.appendChild(cx.allocator, self.stderr_label.?);
        const stderr = try ui.widgets.ScrollArea(.{ .direction = .horizontal, .rubber_band_x = false }).mount(scope, cx);
        self.stderr_scroll = stderr.state;
        self.stderr_viewport = stderr.container;
        stderr.container.setStyleInline(cx.allocator, S.outputViewport(cx.tokens));
        stderr.container.meta.ownership.meta.test_id = "ai.tool.result.stderr_scroll";
        stderr.content.setStyleInline(cx.allocator, S.outputContent(cx.tokens));
        try body.content.appendChild(cx.allocator, stderr.container);
        self.stderr = try ui.textStyled(cx, S.multilineOutput, "");
        self.stderr.meta.ownership.meta.test_id = "ai.tool.result.stderr";
        try stderr.content.appendChild(cx.allocator, self.stderr);
        self.footer = try ui.boxStyled(cx, S.footer, .{});
        self.footer_disclosure = try @import("layout_motion.zig").Disclosure.mount(cx, scope, self.footer, record.expanded);
        try self.root.appendChild(cx.allocator, self.footer_disclosure.root);
        self.feedback = try ui.textStyled(cx, S.text, "执行结果");
        self.feedback.meta.ownership.meta.test_id = "ai.tool.result.feedback";
        try self.footer.appendChild(cx.allocator, self.feedback);
        try self.footer.appendChild(cx.allocator, try ui.spacer(cx));
        const copy_stdout = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.copy, .icon_size = @as(f32, 16), .a11y_label = if (legacy) "复制标准输出" else "复制结果内容", .base_style = S.button(26), .on_click = cx.on(State, self, copyStdout) }).mount(scope, cx);
        self.copy_stdout_button = copy_stdout;
        copy_stdout.meta.ownership.meta.test_id = "ai.tool.result.copy_stdout";
        try self.footer.appendChild(cx.allocator, copy_stdout);
        const copy_stderr = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.clipboard, .icon_size = @as(f32, 16), .a11y_label = if (legacy) "复制错误输出" else "复制错误详情", .base_style = S.button(26), .on_click = cx.on(State, self, copyStderr) }).mount(scope, cx);
        self.copy_stderr_button = copy_stderr;
        copy_stderr.meta.ownership.meta.test_id = "ai.tool.result.copy_stderr";
        try self.footer.appendChild(cx.allocator, copy_stderr);
        _ = ui.clickable(header, cx.on(State, self, toggle));
        try self.select(record.selected);
        self.applyExpanded();
        return self;
    }
    pub fn appendImage(self: *State, reference: @import("../ai/image_attachments.zig").ContentRef, app: ?*@import("zenit_app").App) !void {
        const content = reference.content() orelse return error.EmptyAttachmentResult;
        const preview = try self.scope.createState(ImagePreview, .{ .app = app, .reference = reference.retain() });
        try self.scope.onCleanup(ImagePreview, preview, ImagePreview.cleanup);
        const raster = try ui.boxStyled(self.cx, S.resultImage, .{});
        raster.meta.ownership.meta.test_id = "ai.tool.result.image";
        if (app) |renderer_app| {
            preview.texture = try renderer_app.renderer.image_renderer.loadTexture(content.width, content.height, content.pixels);
            raster.setImage(.{ .texture_id = preview.texture.? });
        }
        try self.image_content.?.appendChild(self.cx.allocator, raster);
    }
    pub fn select(self: *State, index: usize) !void {
        if (self.record.host) |fact| {
            try self.identity.setTextContent(self.cx.allocator, "当前对话");
            const receipt = try std.fmt.allocPrint(self.cx.allocator, "操作 #{d} · {s}", .{ fact.receipt.operation_id, if (fact.receipt.local_released) "本地资源已释放" else "清理待核实" });
            defer self.cx.allocator.free(receipt);
            try self.metadata.setTextContent(self.cx.allocator, receipt);
            var summary: [128]u8 = undefined;
            try self.feedback.setTextContent(self.cx.allocator, if (!fact.receipt.local_released) "清理待核实" else if (fact.receipt.remote_effect_unknown) "执行结果待核实" else self.record.summary(&summary));
            try self.showOutput(fact.content, "");
            return;
        }
        if (self.record.targets.len == 0) {
            try self.identity.setTextContent(self.cx.allocator, "没有已执行的目标");
            try self.metadata.setTextContent(self.cx.allocator, self.record.error_code orelse "尚未执行");
            try self.feedback.setTextContent(self.cx.allocator, if (self.record.error_status) |value| statusLabel(value) else if (self.record.decision == false) "已拒绝" else "尚未执行");
            self.stdout_label.?.setDisplay(.none);
            self.stderr_label.?.setDisplay(.none);
            self.stdout_viewport.?.setDisplay(.none);
            self.stderr_viewport.?.setDisplay(.none);
            self.copy_stdout_button.?.setDisplay(.none);
            self.copy_stderr_button.?.setDisplay(.none);
            return;
        }
        self.record.selected = @min(index, self.record.targets.len - 1);
        const target = self.record.targets[self.record.selected];
        const result = target.result;
        const terminal = std.mem.eql(u8, self.record.name, "run_command") or std.mem.eql(u8, self.record.name, "read_terminal");
        const label = if (result.cwd != null or terminal) try std.fmt.allocPrint(self.cx.allocator, "目录 {s}", .{result.cwd orelse "未知"}) else try self.cx.allocator.dupe(u8, "");
        defer self.cx.allocator.free(label);
        try self.identity.setTextContent(self.cx.allocator, label);
        self.identity.setDisplay(if (label.len == 0) .none else .flex);
        const exit = if (result.exit) |code| try std.fmt.allocPrint(self.cx.allocator, "退出码 {d}", .{code}) else try self.cx.allocator.dupe(u8, if (terminal) "未获退出码" else "");
        defer self.cx.allocator.free(exit);
        const signal = if (result.signal) |value| try std.fmt.allocPrint(self.cx.allocator, "{s}信号 {d}", .{ if (exit.len != 0) " · " else "", value }) else try self.cx.allocator.dupe(u8, "");
        defer self.cx.allocator.free(signal);
        const receipt = if (target.operation_id) |operation_id| try std.fmt.allocPrint(self.cx.allocator, "操作 #{d} · {s}", .{ operation_id, if (result.local_released) "本地资源已释放" else "清理待核实" }) else try self.cx.allocator.dupe(u8, "");
        defer self.cx.allocator.free(receipt);
        const metadata = try std.fmt.allocPrint(self.cx.allocator, "{s}{s}{s}{s}{s}", .{ exit, signal, if (result.truncated) (if (exit.len != 0 or signal.len != 0) " · 输出已截断" else "输出已截断") else "", if (receipt.len != 0 and (exit.len != 0 or signal.len != 0 or result.truncated)) " · " else "", receipt });
        defer self.cx.allocator.free(metadata);
        try self.metadata.setTextContent(self.cx.allocator, metadata);
        self.metadata.setDisplay(if (metadata.len == 0) .none else .flex);
        const state_label = if (!result.local_released and result.remote_effect_unknown) "清理待核实 · 远端执行结果待核实" else if (!result.local_released) "清理待核实" else if (result.remote_effect_unknown) "远端执行结果待核实" else statusLabel(result.status);
        const feedback = if (failureReason(result.error_code)) |reason| try std.fmt.allocPrint(self.cx.allocator, "{s} · {s}", .{ state_label, reason }) else try self.cx.allocator.dupe(u8, state_label);
        defer self.cx.allocator.free(feedback);
        try self.feedback.setTextContent(self.cx.allocator, feedback);
        try self.showOutput(result.stdout, result.stderr);
    }
    fn showOutput(self: *State, output: []const u8, failure: []const u8) !void {
        const stdout = try displayBytes(self.cx.allocator, output);
        defer self.cx.allocator.free(stdout);
        const stderr = try displayBytes(self.cx.allocator, failure);
        defer self.cx.allocator.free(stderr);
        try self.stdout.setTextContent(self.cx.allocator, stdout);
        try self.stderr.setTextContent(self.cx.allocator, stderr);
        self.stdout.setStyleInline(self.cx.allocator, .{ .width = .{ .px = @import("ai_message_view.zig").textWidth(self.cx, stdout, 11, 400) }, .flex_shrink = 0 });
        self.stderr.setStyleInline(self.cx.allocator, .{ .width = .{ .px = @import("ai_message_view.zig").textWidth(self.cx, stderr, 11, 400) }, .flex_shrink = 0 });
        self.stdout_label.?.setDisplay(if (stdout.len == 0) .none else .flex);
        self.stdout_viewport.?.setDisplay(if (stdout.len == 0) .none else .flex);
        self.stderr_label.?.setDisplay(if (stderr.len == 0) .none else .flex);
        self.stderr_viewport.?.setDisplay(if (stderr.len == 0) .none else .flex);
        self.copy_stdout_button.?.setDisplay(if (stdout.len == 0) .none else .flex);
        self.copy_stderr_button.?.setDisplay(if (stderr.len == 0) .none else .flex);
        const out_lines = 1 + std.mem.count(u8, std.mem.trimEnd(u8, stdout, "\r\n"), "\n");
        const err_lines = 1 + std.mem.count(u8, std.mem.trimEnd(u8, stderr, "\r\n"), "\n");
        self.stdout_viewport.?.setStyleInline(self.cx.allocator, .{ .height = .{ .px = @as(f32, @floatFromInt(out_lines)) * 16 + 8 } });
        self.stderr_viewport.?.setStyleInline(self.cx.allocator, .{ .height = .{ .px = @as(f32, @floatFromInt(err_lines)) * 16 + 8 } });
        self.stdout_scroll.scroll_x = 0;
        self.stderr_scroll.scroll_x = 0;
        self.stdout_scroll.scroll_y = 0;
        self.stderr_scroll.scroll_y = 0;
        self.cx.requestRedraw();
    }
    fn applyExpanded(self: *State) void {
        if (self.disclosure_icon) |node| {
            const asset = if (self.record.expanded) ui.icons.chevron_down else ui.icons.chevron_right;
            if (asset.icon_id) |id| if (asset.pickRep(14)) |rep| node.setIcon(.{ .icon_id = id, .rep = rep, .tint = @import("app_theme.zig").current().fg_2 });
        }
        self.body_disclosure.setExpanded(self.record.expanded);
        self.footer_disclosure.setExpanded(self.record.expanded);
        self.root.setStyleInline(self.cx.allocator, .{ .height = .{ .fit = .{} } });
    }
    fn hoverDisclosure(self: *State) void {
        self.status_icon.?.setOpacityRaw(0);
        self.disclosure_icon.?.setOpacityRaw(1);
        self.cx.requestRedraw();
    }
    fn leaveDisclosure(self: *State) void {
        self.status_icon.?.setOpacityRaw(1);
        self.disclosure_icon.?.setOpacityRaw(0);
        self.cx.requestRedraw();
    }
    fn toggle(self: *State) void {
        if (self.on_toggle) |handler| handler.invoke();
        self.record.expanded = !self.record.expanded;
        self.applyExpanded();
        self.cx.requestRedraw();
    }
    fn copy(self: *State, bytes: []const u8, _: []const u8) void {
        const display = displayBytes(self.cx.allocator, bytes) catch return;
        defer self.cx.allocator.free(display);
        // The outcome remains visible after a copy, especially unknown effects.
        _ = ui.platform_services.clipboardSetText(self.cx.system_sdk, display);
    }
    fn copyCommand(self: *State) void {
        self.copy(self.record.command, if (@import("../ai/plugin_tools.zig").legacyName(self.record.name)) "已复制完整命令 / 路径" else "已复制调用参数");
    }
    fn copyStdout(self: *State) void {
        if (self.record.host) |fact| {
            self.copy(fact.content, "已复制结果内容");
            return;
        }
        if (self.record.targets.len > 0) self.copy(self.record.targets[self.record.selected].result.stdout, if (@import("../ai/plugin_tools.zig").legacyName(self.record.name)) "已复制 stdout" else "已复制结果内容");
    }
    fn copyStderr(self: *State) void {
        if (self.record.targets.len > 0) self.copy(self.record.targets[self.record.selected].result.stderr, if (@import("../ai/plugin_tools.zig").legacyName(self.record.name)) "已复制 stderr" else "已复制错误详情");
    }
};
const Row = struct {
    view: *State,
    index: usize,
    test_id: [96]u8 = @splat(0),
    label: ?[]u8 = null,
    fn cleanup(self: *Row) void {
        if (self.label) |label| self.view.cx.allocator.free(label);
    }
    fn select(self: *Row) void {
        self.view.select(self.index) catch {};
    }
};
fn ownerIsGroup(owner: scope_mod.Owner) bool {
    return owner == .group;
}
fn ownerId(owner: scope_mod.Owner) u64 {
    return switch (owner) {
        .session => |id| id,
        .group => |id| id,
    };
}
fn remoteUnknown(result: @import("../ai/tool_loop.zig").TargetResult) bool {
    return result.remote_effect_unknown;
}
fn targetStatus(result: @import("../ai/tool_loop.zig").TargetResult, buffer: []u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}{s}", .{ statusLabel(result.status), if (remoteUnknown(result)) " · 远端待核实" else "" }) catch statusLabel(result.status);
}
fn displayBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return @import("formatted_output.zig").format(allocator, bytes);
}

fn toolTitle(name: []const u8) []const u8 {
    if (@import("ai_tool_titles.zig").title(name)) |label| return label;
    if (std.mem.eql(u8, name, "run_command")) return "执行命令";
    if (std.mem.eql(u8, name, "read_terminal")) return "读取终端";
    if (std.mem.eql(u8, name, "list_remote_files")) return "列出远程文件";
    if (std.mem.eql(u8, name, "read_remote_file")) return "读取远程文件";
    return "工具调用";
}

fn statusLabel(status: @import("../ai/tool_loop.zig").Status) []const u8 {
    return switch (status) {
        .succeeded => "已完成",
        .failed => "执行失败",
        .rejected => "已拒绝",
        .cancelled => "已取消",
        .timed_out => "执行超时",
        .unknown => "结果待核实",
        .skipped => "已跳过",
    };
}

fn failureReason(code: ?[]const u8) ?[]const u8 {
    const value = code orelse return null;
    if (std.mem.eql(u8, value, "GroupMembershipChanged")) return "组成员已变化，原批准失效";
    if (std.mem.eql(u8, value, "GroupRemoved")) return "原终端组已关闭";
    if (std.mem.eql(u8, value, "StaleBinding") or std.mem.eql(u8, value, "StaleSession")) return "原会话连接已失效";
    if (std.mem.eql(u8, value, "ServiceUnavailable") or std.mem.eql(u8, value, "ToolHostUnavailable")) return "原会话服务不可用";
    if (std.mem.eql(u8, value, "TargetOutsideAssistant")) return "目标不在原助手范围内";
    if (std.mem.eql(u8, value, "ToolApprovalRejected")) return "本次执行未获批准";
    if (std.mem.eql(u8, value, "UnknownDirectory")) return "原会话工作目录未知";
    return null;
}

const ImagePreview = struct {
    app: ?*@import("zenit_app").App,
    reference: @import("../ai/image_attachments.zig").ContentRef,
    texture: ?u32 = null,
    fn cleanup(self: *ImagePreview) void {
        if (self.texture) |texture| if (self.app) |app| app.renderer.image_renderer.unloadTexture(texture);
        self.reference.release();
    }
};
