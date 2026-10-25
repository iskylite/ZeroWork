//! Shared host challenge UI. Uses the existing authentication theme/styles and
//! public Modal/Input/Button/ScrollArea; no plugin draws authentication UI.
const std = @import("std");
const ui = @import("ui");
const challenge = @import("../host/challenge_host.zig");
const identity = @import("../host/identity.zig");
const S = @import("auth_challenge_styles.zig");
pub const PrefillGuard = struct {
    context: *anyopaque,
    valid: *const fn (*anyopaque, u64, ?i128) bool,
};
const Current = struct { owner: challenge.Owner, request_id: u64, generation: u64, kind: challenge.Kind, field_count: usize, choice_count: usize };
const Choice = struct {
    presenter: *Presenter,
    index: usize,
    root: *ui.Node,
    label: *ui.Node,
    value: *ui.Signal([]const u8),
    id: [48]u8 = undefined,
    fn choose(self: *Choice) void {
        self.presenter.choose(self.index);
    }
};
const FieldControl = struct {
    presenter: *Presenter,
    root: *ui.Node,
    label: *ui.Node,
    input: ui.widgets.input.InputResult,
    id: [48]u8 = undefined,
    fn changed(self: *FieldControl, _: []const u8) void {
        self.presenter.prefill_edited = true;
        self.presenter.refreshSubmit();
    }
    fn submitted(self: *FieldControl, _: []const u8) void {
        self.presenter.submit();
    }
};
pub const Presenter = struct {
    cx: *ui.Cx,
    host: *challenge.Host,
    open: *ui.Signal(bool),
    modal: ui.widgets.ModalResult = undefined,
    title: *ui.Node = undefined,
    detail: *ui.Node = undefined,
    source: *ui.Node = undefined,
    material: *ui.Node = undefined,
    material_scroll: *ui.Node = undefined,
    problem: *ui.Node = undefined,
    input: ui.widgets.input.InputResult = undefined,
    fields: [16]FieldControl = undefined,
    fields_scroll: *ui.Node = undefined,
    prefill_window: ?u64 = null,
    prefill_expires_ns: ?i128 = null,
    prefill_guard: ?PrefillGuard = null,
    prefill_edited: bool = false,
    submit_button: *ui.Node = undefined,
    submit_disabled: *ui.Signal(bool) = undefined,
    submit_label: *ui.Signal([]const u8) = undefined,
    choices: [32]Choice = undefined,
    choice_scroll: *ui.Node = undefined,
    current: ?Current = null,
    pub fn isVisible(self: *const Presenter) bool {
        return self.open.peek();
    }
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, host: *challenge.Host) !*Presenter {
        const open = try scope.createSignal(bool, false);
        const self = try cx.bindState(Presenter, .{ .cx = cx, .host = host, .open = open });
        self.modal = try ui.widgets.Modal(.{ .open = ui.split(open, cx.on(Presenter, self, openChanged)), .width = S.width(.password), .max_height = @max(160, cx.viewport.height - 16), .background = S.theme.current().overlay, .close_on_overlay = false }).mount(scope, cx);
        self.modal.dialog.meta.ownership.meta.test_id = "plugin.challenge.modal";
        self.modal.body.setStyleInline(cx.allocator, .{ .direction = .column, .width = .fill(), .height = .{ .fit = .{} }, .padding = ui.Padding.all(S.padding), .gap = S.gap });
        if (!self.modal.portaled) if (cx.root) |root| try root.appendChild(cx.allocator, self.modal.overlay);
        self.title = try label(cx, self.modal.body, "", S.text(13, 600, false));
        self.title.meta.ownership.meta.test_id = "plugin.challenge.title";
        self.source = try label(cx, self.modal.body, "", S.text(11, 500, false));
        self.source.meta.ownership.meta.test_id = "plugin.challenge.source";
        self.detail = try label(cx, self.modal.body, "", S.text(11, 400, false));
        self.detail.meta.ownership.meta.test_id = "plugin.challenge.detail";
        const material_scroll = try ui.widgets.ScrollArea(.{ .height = 120 }).mount(scope, cx);
        self.material_scroll = material_scroll.container;
        try self.modal.body.appendChild(cx.allocator, material_scroll.container);
        self.material = try label(cx, material_scroll.content, "", S.text(11, 400, true));
        self.material.meta.ownership.meta.test_id = "plugin.challenge.material";
        self.input = try ui.widgets.Input(.{ .input_type = .password, .on_change = cx.on(Presenter, self, primaryChanged), .on_submit = cx.on(Presenter, self, submitted) }).mountResult(scope, cx);
        self.input.node.setStyleInline(cx.allocator, S.inputWrapper(S.field_height));
        self.input.input_container.setStyleInline(cx.allocator, S.input(S.field_height, false));
        self.input.input_container.meta.ownership.meta.test_id = "plugin.challenge.secret";
        self.input.input_container.behavior.interaction.a11y = .{ .role = .textbox, .label = "本次连接认证输入" };
        S.tuneInput(&self.input);
        if (self.input.node.meta.ownership.scope.scope) |input_scope| try input_scope.onCleanup(ui.widgets.input.InputResult, &self.input, secureOnDispose);
        try self.modal.body.appendChild(cx.allocator, self.input.node);
        const form_scroll = try ui.widgets.ScrollArea(.{ .height = 180 }).mount(scope, cx);
        self.fields_scroll = form_scroll.container;
        form_scroll.content.setStyleInline(cx.allocator, S.stack());
        try self.modal.body.appendChild(cx.allocator, form_scroll.container);
        for (&self.fields, 0..) |*field, i| {
            const root = try ui.box(cx, S.field(), .{});
            const text = try label(cx, root, "", S.text(11, 500, false));
            const input = try ui.widgets.Input(.{ .input_type = .password, .on_change = cx.on(FieldControl, field, FieldControl.changed), .on_submit = cx.on(FieldControl, field, FieldControl.submitted) }).mountResult(scope, cx);
            input.node.setStyleInline(cx.allocator, S.inputWrapper(S.field_height));
            input.input_container.setStyleInline(cx.allocator, S.input(S.field_height, false));
            var mutable_input = input;
            S.tuneInput(&mutable_input);
            field.* = .{ .presenter = self, .root = root, .label = text, .input = mutable_input };
            if (input.node.meta.ownership.scope.scope) |input_scope| try input_scope.onCleanup(ui.widgets.input.InputResult, &field.input, secureOnDispose);
            input.input_container.meta.ownership.meta.test_id = try std.fmt.bufPrint(&field.id, "plugin.challenge.answer.{d}", .{i});
            try root.appendChild(cx.allocator, input.node);
            try form_scroll.content.appendChild(cx.allocator, root);
            root.setDisplay(.none);
        }
        const scroll = try ui.widgets.ScrollArea(.{ .height = 180 }).mount(scope, cx);
        self.choice_scroll = scroll.container;
        scroll.content.setStyleInline(cx.allocator, S.stack());
        try self.modal.body.appendChild(cx.allocator, scroll.container);
        for (&self.choices, 0..) |*choice, i| {
            const value = try scope.createSignal([]const u8, " ");
            const button = try ui.widgets.Button(.{ .label = value, .variant = .secondary, .on_click = cx.on(Choice, choice, Choice.choose) }).mount(scope, cx);
            choice.* = .{ .presenter = self, .index = i, .root = button, .label = textNode(button).?, .value = value };
            button.meta.ownership.meta.test_id = try std.fmt.bufPrint(&choice.id, "plugin.challenge.choice.{d}", .{i});
            try scroll.content.appendChild(cx.allocator, button);
            button.setDisplay(.none);
        }
        self.problem = try label(cx, self.modal.body, "", S.text(11, 400, false));
        self.problem.meta.ownership.meta.test_id = "plugin.challenge.error";
        const footer = try ui.box(cx, S.footer(), .{});
        try self.modal.body.appendChild(cx.allocator, footer);
        const cancel_button = try ui.widgets.Button(.{ .label = "取消", .variant = .secondary, .on_click = cx.on(Presenter, self, cancel) }).mount(scope, cx);
        cancel_button.meta.ownership.meta.test_id = "plugin.challenge.cancel";
        try footer.appendChild(cx.allocator, cancel_button);
        self.submit_disabled = try scope.createSignal(bool, true);
        self.submit_label = try scope.createSignal([]const u8, "确认");
        self.submit_button = try ui.widgets.Button(.{ .label = self.submit_label, .disabled = self.submit_disabled, .variant = .primary, .on_click = cx.on(Presenter, self, submit) }).mount(scope, cx);
        self.submit_button.meta.ownership.meta.test_id = "plugin.challenge.submit";
        try footer.appendChild(cx.allocator, self.submit_button);
        return self;
    }
    pub fn update(self: *Presenter, active_owner: ?identity.SessionHandle) !void {
        if (self.current) |current| {
            const state = self.host.stateFor(current.owner, current.request_id, current.generation);
            if (state == .pending) return;
            self.hide();
        }
        var chosen: ?challenge.View = null;
        var index: usize = 0;
        while (self.host.snapshot(index, active_owner)) |view| : (index += 1) {
            if (view.state != .pending) continue;
            if (chosen == null or !view.background) chosen = view;
            if (!view.background) break;
        }
        const view = chosen orelse return;
        self.clearInput();
        self.current = .{ .owner = view.owner, .request_id = view.request_id, .generation = view.generation, .kind = view.kind, .field_count = view.payload.fields.len, .choice_count = view.payload.choices.len };
        try self.title.setTextContent(self.cx.allocator, view.payload.title);
        try self.detail.setTextContent(self.cx.allocator, view.payload.detail);
        try self.source.setTextContent(self.cx.allocator, if (view.background and view.payload.source_name.len == 0) "来自后台会话的请求" else view.payload.source_name);
        self.source.setDisplay(if (view.background or view.payload.source_name.len > 0) .flex else .none);
        try self.material.setTextContent(self.cx.allocator, view.payload.material);
        self.material_scroll.setDisplay(if (view.payload.material.len != 0) .flex else .none);
        self.material_scroll.setStyle(self.cx.allocator, .height, .{ .px = @min(120, @max(60, self.cx.viewport.height - 460)) });
        self.input.node.setDisplay(if (view.kind == .secret_input and view.payload.fields.len == 0) .flex else .none);
        self.fields_scroll.setDisplay(if (view.payload.fields.len != 0) .flex else .none);
        self.fields_scroll.setStyle(self.cx.allocator, .height, .{ .px = @min(@as(f32, @floatFromInt(view.payload.fields.len)) * 68, @max(120, self.cx.viewport.height - 320)) });
        for (&self.fields, 0..) |*field, i| {
            if (i >= view.payload.fields.len) {
                field.root.setDisplay(.none);
                continue;
            }
            const specification = view.payload.fields[i];
            try field.label.setTextContent(self.cx.allocator, specification.label);
            field.input.state.input_type = if (specification.secret) .password else .text;
            field.input.state.dirty = true;
            field.root.setDisplay(.flex);
        }
        self.choice_scroll.setDisplay(if (view.payload.choices.len != 0) .flex else .none);
        self.choice_scroll.setStyle(self.cx.allocator, .height, .{ .px = @min(@as(f32, @floatFromInt(view.payload.choices.len)) * 40, @max(80, self.cx.viewport.height - 360)) });
        self.submit_button.setDisplay(if (view.payload.choices.len != 0) .none else .flex);
        self.submit_label.set(view.payload.submit_label);
        for (&self.choices, 0..) |*choice, i| {
            if (i >= view.payload.choices.len) {
                choice.root.setDisplay(.none);
                continue;
            }
            choice.value.set(view.payload.choices[i].label);
            choice.root.setDisplay(.flex);
        }
        self.refreshSubmit();
        self.open.set(true);
        self.cx.requestRedraw();
    }
    fn primaryChanged(self: *Presenter, _: []const u8) void {
        self.refreshSubmit();
    }
    fn refreshSubmit(self: *Presenter) void {
        const current = self.current orelse {
            self.submit_disabled.set(true);
            return;
        };
        var allowed = true;
        if (current.field_count != 0) {
            var index: usize = 0;
            while (self.host.snapshot(index, null)) |view| : (index += 1) if (view.owner.eql(current.owner) and view.request_id == current.request_id and view.generation == current.generation) {
                for (view.payload.fields, self.fields[0..view.payload.fields.len]) |specification, field| {
                    const value = field.input.state.getText();
                    if (value.len == 0 or value.len > specification.max_bytes) allowed = false;
                    if (specification.confirmation) |confirmation| if (!std.mem.eql(u8, value, confirmation)) {
                        allowed = false;
                    };
                }
                break;
            };
        } else if (current.kind == .secret_input) allowed = self.input.state.getText().len != 0;
        self.submit_disabled.set(!allowed);
    }
    fn submitted(self: *Presenter, _: []const u8) void {
        self.submit();
    }
    fn submit(self: *Presenter) void {
        const current = self.current orelse return;
        if (current.choice_count != 0) return;
        var answers: [16][]const u8 = undefined;
        if (current.field_count != 0) {
            for (self.fields[0..current.field_count], 0..) |field, i| {
                if (field.input.state.imeIsComposing()) return;
                answers[i] = field.input.state.getText();
            }
            if (!self.prefill_edited) if (self.prefill_window) |window| {
                if (self.prefill_guard) |guard| if (!guard.valid(guard.context, window, self.prefill_expires_ns)) {
                    self.clearInput();
                    self.fail("自动填入内容已过期，请重新填写");
                    return;
                };
            };
            self.send(current, .{ .fields = answers[0..current.field_count] });
            return;
        }
        const reply: challenge.Reply = switch (current.kind) {
            .secret_input => blk: {
                const secret = self.input.state.getText();
                if (secret.len == 0) {
                    self.fail("请输入本次认证信息");
                    return;
                }
                break :blk .{ .secret_input = secret };
            },
            .trust_material => .{ .trust_material = true },
            .choice => return,
        };
        self.send(current, reply);
    }
    fn choose(self: *Presenter, index: usize) void {
        const current = self.current orelse return;
        var i: usize = 0;
        while (self.host.snapshot(i, null)) |view| : (i += 1) if (view.owner.eql(current.owner) and view.request_id == current.request_id and view.generation == current.generation) {
            if (index >= view.payload.choices.len) return;
            self.send(current, .{ .choice = view.payload.choices[index].value });
            return;
        };
    }
    fn send(self: *Presenter, current: Current, reply: challenge.Reply) void {
        const ns = @import("../platform/realtime.zig").monotonicNs();
        self.host.submitAnswer(current.owner, current.request_id, current.generation, reply, @intCast(@max(0, ns) / std.time.ns_per_ms)) catch |err| {
            self.clearInput();
            self.fail(@errorName(err));
            return;
        };
        self.hide();
    }
    fn cancel(self: *Presenter) void {
        const current = self.current orelse return;
        _ = self.host.withdraw(current.owner, current.request_id, current.generation) catch {};
        self.hide();
    }
    fn openChanged(self: *Presenter, value: bool) void {
        if (!value) {
            // Let composing text consume Escape before challenge cancellation.
            if (self.input.state.imeIsComposing()) return;
            for (self.fields) |field| if (field.input.state.imeIsComposing()) return;
            self.cancel();
        }
    }
    fn hide(self: *Presenter) void {
        self.clearInput();
        self.current = null;
        self.submit_disabled.set(true);
        self.open.set(false);
        self.cx.requestRedraw();
    }
    pub fn prefill(self: *Presenter, owner: challenge.Owner, request_id: u64, generation: u64, code: []const u8, window: u64, expires_ns: ?i128, guard: PrefillGuard) !bool {
        const current = self.current orelse return false;
        if (!current.owner.eql(owner) or current.request_id != request_id or current.generation != generation or current.field_count != 1 or self.prefill_edited) return false;
        const field = &self.fields[0];
        if (field.input.state.imeIsComposing()) return false;
        if (self.prefill_window) |old| {
            if (old == window) return false;
        } else if (field.input.state.getText().len != 0) return false;
        try field.input.state.applyExternalText(code);
        self.prefill_window = window;
        self.prefill_expires_ns = expires_ns;
        self.prefill_guard = guard;
        self.refreshSubmit();
        self.cx.requestRedraw();
        return true;
    }
    fn clearInput(self: *Presenter) void {
        self.prefill_window = null;
        self.prefill_expires_ns = null;
        self.prefill_guard = null;
        self.prefill_edited = false;
        for (&self.fields) |*field| wipe(&field.input);
        wipe(&self.input);
        self.problem.setTextContent(self.cx.allocator, "") catch {};
    }
    fn wipe(input: *ui.widgets.input.InputResult) void {
        secureOnDispose(input);
        if (input.value) |value| value.set("");
        input.state.applyExternalText("") catch {};
        input.state.dirty = true;
    }
    fn secureOnDispose(input: *ui.widgets.input.InputResult) void {
        // This runs in the Input's own scope, before its state and owned model
        // are disposed. Never depend on parent scope/state destruction order.
        if (input.value) |value| if (value.slice_store) |store| {
            for (store.bufs) |buffer| std.crypto.secureZero(u8, buffer);
        };
        // Prevent undo or retained widget buffers restoring an earlier secret.
        for (&input.state.undo_stack) |*snapshot| if (snapshot.text) |bytes| std.crypto.secureZero(u8, @constCast(bytes));
        for (&input.state.redo_stack) |*snapshot| if (snapshot.text) |bytes| std.crypto.secureZero(u8, @constCast(bytes));
        std.crypto.secureZero(u8, &input.state.buffer);
    }
    fn fail(self: *Presenter, message: []const u8) void {
        self.problem.setTextContent(self.cx.allocator, message) catch {};
        self.cx.requestRedraw();
    }
};
fn label(cx: *ui.Cx, parent: *ui.Node, text: []const u8, style: ui.TextStyle) !*ui.Node {
    const node = try ui.text(cx, text, style);
    node.setStyle(cx.allocator, .width, .fill());
    try parent.appendChild(cx.allocator, node);
    return node;
}
fn textNode(node: *ui.Node) ?*ui.Node {
    if (node.getText() != null) return node;
    for (node.children.items) |child| if (textNode(child)) |found| return found;
    return null;
}
