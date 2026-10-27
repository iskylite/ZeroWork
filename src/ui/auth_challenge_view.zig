//! One view of InteractiveBridge's frozen challenge, not an authentication
//! controller. show/setDetails/hide run from the host's safe UI hook. Handlers
//! only propose a response to that exact request; they never rebuild their tree.
const std = @import("std");
const ui = @import("ui");
pub const auth = @import("../proto/ssh/auth_challenge.zig");
const realtime = @import("../platform/realtime.zig");
const S = @import("auth_challenge_styles.zig");
const TotpPrefill = @import("../proto/ssh/totp_prefill.zig");

pub const Callbacks = struct {
    context: *anyopaque,
    /// Reply/answer slices are valid only during this call. The owner must
    /// synchronously call bridge.submit (or copy), never retain these slices.
    submit: *const fn (*anyopaque, auth.RequestIdentity, auth.Reply) anyerror!void,
    /// Cancels the captured connection job. Release acknowledgement belongs
    /// to that job; this view does not claim that resources have been released.
    cancel: *const fn (*anyopaque, auth.RequestIdentity) void,
};

/// Public metadata absent from Snapshot. All strings are copied by setDetails.
/// Bind this data to the same frozen request, not the currently selected asset.
pub const Details = struct {
    display_name: []const u8 = "",
    route_label: []const u8 = "",
    private_key_path: []const u8 = "",
    algorithm: []const u8 = "",
    fingerprint: []const u8 = "",
    previous_algorithm: []const u8 = "",
    previous_fingerprint: []const u8 = "",
    store_path: []const u8 = "",
};

const Field = struct {
    view: *View,
    input: ui.widgets.input.InputResult,
    secret: bool,
    revealed: bool = false,
    eye: ?*ui.Node = null,
    eye_icon: ?*ui.Node = null,
    id: [48]u8 = @splat(0),
    eye_id: [48]u8 = @splat(0),

    fn changed(self: *Field, _: []const u8) void {
        if (self.view.otp_prefill != null) self.view.otp_edited = true;
        self.view.local_failure = null;
        self.view.refreshState() catch {};
    }
    fn submit(self: *Field, _: []const u8) void {
        self.view.submit();
    }
    fn reveal(self: *Field) void {
        if (!self.view.acceptsInput() or !self.secret) return;
        self.revealed = !self.revealed;
        self.input.state.input_type = if (self.revealed) .text else .password;
        self.input.state.dirty = true;
        const asset = if (self.revealed) ui.icons.get("eye-off").? else ui.icons.get("eye").?;
        if (self.eye_icon) |icon| if (asset.icon_id) |id| if (asset.pickRep(16)) |rep| icon.setIcon(.{ .icon_id = id, .rep = rep, .tint = S.theme.current().fg_2 });
        if (self.eye) |eye| eye.behavior.interaction.a11y = .{ .role = .button, .label = if (self.revealed) "隐藏认证输入" else "显示认证输入" };
        self.view.cx.requestRedraw();
    }
};

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    material: ?*@import("background_layers.zig").View = null,
    callbacks: Callbacks,
    /// Append this to the original connection progress authentication area.
    /// It is hidden in modal mode, and contains the form in protected mode.
    root: *ui.Node,
    snapshot: ?auth.Snapshot = null,
    details: Details = .{},
    details_arena: ?std.heap.ArenaAllocator = null,
    inline_form: bool = false,
    visible: bool = false,
    pending: bool = false,
    cancel_requested: bool = false,
    local_failure: ?anyerror = null,
    otp_prefill: ?TotpPrefill.Suggestion = null,
    otp_edited: bool = false,
    otp_clock: TotpPrefill.Clock = .{},
    content_scope: ?*ui.Scope = null,
    form: ?*ui.Node = null,
    modal: ?ui.widgets.ModalResult = null,
    open: *ui.Signal(bool),
    disabled: *ui.Signal(bool),
    submit_disabled: *ui.Signal(bool),
    trust_disabled: *ui.Signal(bool),
    fields: [auth.max_prompts]Field = undefined,
    field_count: usize = 0,
    own_labels: std.ArrayList(struct { node: *ui.Node, strong: bool }) = .empty,
    title: *ui.Node = undefined,
    header_icon: *ui.Node = undefined,
    header_close: *ui.Node = undefined,
    header_close_icon: *ui.Node = undefined,
    cancel_label: *ui.Node = undefined,
    trust_once_label: ?*ui.Node = null,
    identity_name: *ui.Node = undefined,
    identity_endpoint: *ui.Node = undefined,
    identity_icon: *ui.Node = undefined,
    hop: *ui.Node = undefined,
    key_label: ?*ui.Node = null,
    fingerprint: ?*ui.Node = null,
    previous_key_label: ?*ui.Node = null,
    previous_fingerprint: ?*ui.Node = null,
    private_key_path: ?*ui.Node = null,
    store_path: ?*ui.Node = null,
    notice_title: *ui.Node = undefined,
    notice_detail: *ui.Node = undefined,
    cancel_button: *ui.Node = undefined,
    actions: *ui.Node = undefined,
    submit_button: *ui.Node = undefined,
    submit_label: *ui.Node = undefined,
    trust_once_button: ?*ui.Node = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try cx.allocator.create(View);
        var registered = false;
        errdefer if (!registered) cx.allocator.destroy(self);
        self.* = .{
            .cx = cx,
            .scope = scope,
            .callbacks = callbacks,
            .root = try ui.box(cx, S.inlineRoot(), .{}),
            .open = try scope.createSignal(bool, false),
            .disabled = try scope.createSignal(bool, true),
            .submit_disabled = try scope.createSignal(bool, true),
            .trust_disabled = try scope.createSignal(bool, true),
        };
        self.root.meta.ownership.meta.test_id = "auth.challenge.inline";
        try scope.onCleanup(View, self, cleanup);
        registered = true;
        return self;
    }

    /// Inline authentication inherits its connection dialog's material; the
    /// independently presented challenge receives its own image-only floor.
    pub fn setMaterial(self: *View, material: *@import("background_layers.zig").View) !void {
        if (self.modal) |modal| try material.isolate(self.scope, modal.dialog);
        self.material = material;
    }

    /// Snapshot is self-contained and copied by value. Repeated state polling
    /// for the same request never remounts controls or replaces their text.
    pub fn show(self: *View, snapshot: auth.Snapshot) !void {
        if (snapshot.prompt_count > auth.max_prompts) return error.InvalidChallengePrompt;
        const same = if (self.snapshot) |current| current.identity.eql(snapshot.identity) else false;
        if (same) {
            // Presentation and prompts are frozen at publication. A global
            // setting save cannot move this form or change its input schema.
            self.snapshot.?.state = snapshot.state;
            self.snapshot.?.failure = snapshot.failure;
            self.snapshot.?.expires_at_ns = snapshot.expires_at_ns;
            if (!self.visible) {
                self.visible = true;
                self.root.setDisplay(if (self.inline_form) .flex else .none);
                if (!self.inline_form) self.open.set(true);
            }
            if (snapshot.state == .failed or snapshot.state == .expired or snapshot.state == .completed or snapshot.state == .cancelled) {
                self.pending = false;
                self.local_failure = null;
            }
            try self.refreshState();
            return;
        }
        if (self.snapshot) |current| {
            if (current.identity.key.eql(snapshot.identity.key) and snapshot.identity.request_id < current.identity.request_id)
                return error.StaleChallenge;
        }
        self.clearFields();
        self.clearForm();
        self.clearDetails();
        self.snapshot = snapshot;
        self.pending = false;
        self.cancel_requested = false;
        self.local_failure = null;
        self.visible = true;
        self.inline_form = snapshot.kind == .keyboard_interactive and snapshot.presentation == .protected_form;
        self.root.setDisplay(if (self.inline_form) .flex else .none);
        self.open.set(false);
        if (!self.inline_form) try self.ensureModal();
        try self.buildForm();
        try self.refreshDetails();
        try self.refreshState();
        if (!self.inline_form) self.open.set(true);
        // Trust decisions default to cancel, never implicit Enter approval.
        if (isHostKey(snapshot.kind) or self.field_count == 0) self.cx.setFocus(self.cancel_button) else if (self.acceptsInput()) self.cx.setFocus(self.fields[0].input.input_container);
        self.cx.requestRedraw();
    }

    pub fn setDetails(self: *View, identity: auth.RequestIdentity, details: Details) !void {
        const current = self.snapshot orelse return error.ChallengeNotVisible;
        if (!self.visible or !current.identity.eql(identity)) return error.StaleChallenge;
        var arena = std.heap.ArenaAllocator.init(self.cx.allocator);
        errdefer arena.deinit();
        var copy: Details = undefined;
        inline for (@typeInfo(Details).@"struct".field_names) |field| @field(copy, field) = try arena.allocator().dupe(u8, @field(details, field));
        self.clearDetails();
        self.details_arena = arena;
        self.details = copy;
        try self.refreshDetails();
        try self.refreshState();
    }

    /// Populate the existing OTP Input only. The host has already validated
    /// the frozen hop/seed; confirmation still goes through normal submit.
    pub fn prefillOtp(self: *View, proposal: TotpPrefill.Suggestion, clock: TotpPrefill.Clock) !bool {
        const snapshot = self.snapshot orelse return false;
        if (!self.acceptsInput() or !TotpPrefill.eligible(&snapshot) or !snapshot.identity.eql(proposal.identity) or !proposal.validAt(clock.now()) or self.field_count != 1 or self.isComposing()) return false;
        if (self.otp_prefill) |old| {
            if (self.otp_edited or old.window == proposal.window) return false;
        } else if (self.fields[0].input.state.getText().len != 0) return false;
        try self.fields[0].input.state.applyExternalText(proposal.code.slice());
        if (self.otp_prefill) |*old| old.deinit();
        self.otp_prefill = proposal;
        self.otp_edited = false;
        self.otp_clock = clock;
        try self.refreshState();
        self.cx.requestRedraw();
        return true;
    }

    /// Called after an owner transition/release receipt; not a cancel command.
    pub fn hide(self: *View) void {
        if (!self.visible and !self.open.peek()) return;
        self.clearFields();
        self.visible = false;
        self.open.set(false);
        self.root.setDisplay(.none);
        self.disabled.set(true);
        self.submit_disabled.set(true);
        self.trust_disabled.set(true);
        self.cx.requestRedraw();
    }
    pub fn isVisible(self: *const View) bool {
        return self.visible;
    }
    pub fn isInline(self: *const View) bool {
        return self.visible and self.inline_form;
    }
    pub fn isComposing(self: *const View) bool {
        for (self.fields[0..self.field_count]) |field| if (field.input.state.imeIsComposing()) return true;
        return false;
    }
    /// Repaint existing public nodes after global theme/material publication.
    /// No input, cursor, selection, undo history or IME composition is replaced.
    pub fn retheme(self: *View) !void {
        const snapshot = self.snapshot orelse return;
        const c = S.theme.current();
        if (self.form) |form| form.setStyleInline(self.cx.allocator, S.form(if (self.inline_form) 0 else form.style.width.px, form.style.height.px, self.inline_form));
        if (self.modal) |modal| modal.dialog.setBackground(c.overlay);
        _ = self.header_icon.setTint(switch (snapshot.kind) {
            .host_key_unknown => c.warn_ink,
            .host_key_changed => c.danger_ink,
            else => c.accent,
        });
        _ = self.header_close_icon.setTint(c.fg_2);
        _ = self.identity_icon.setTint(c.fg_2);
        for (self.own_labels.items) |entry| entry.node.setTextColor(if (entry.strong) c.fg_1 else c.fg_2);
        self.title.setTextColor(c.fg_1);
        self.identity_name.setTextColor(c.fg_1);
        self.identity_endpoint.setTextColor(c.fg_2);
        self.hop.setTextColor(c.fg_2);
        self.header_close.setStyleInline(self.cx.allocator, S.close());
        self.cancel_button.setStyleInline(self.cx.allocator, S.button(if (isHostKey(snapshot.kind)) 104 else 100, false, false));
        self.cancel_label.setTextColor(c.fg_2);
        if (self.trust_once_button) |node| node.setStyleInline(self.cx.allocator, S.button(132, false, false));
        if (self.trust_once_label) |node| node.setTextColor(c.fg_2);
        self.submit_button.setStyleInline(self.cx.allocator, S.button(switch (snapshot.kind) {
            .host_key_unknown => 146,
            .host_key_changed => 172,
            .keyboard_interactive => 136,
            else => 142,
        }, true, snapshot.kind == .host_key_changed));
        self.submit_label.setTextColor(S.actionText(true).color);
        self.notice_detail.setTextColor(c.fg_2);
        for (self.fields[0..self.field_count]) |*field| {
            const h = if (snapshot.kind == .host_key_changed) @as(f32, 32) else S.field_height;
            field.input.input_container.setStyleInline(self.cx.allocator, S.input(h, field.secret));
            field.input.state.tokens = self.cx.tokens;
            field.input.state.dirty = true;
            if (field.eye) |node| node.setStyleInline(self.cx.allocator, S.eye(h));
            if (field.eye_icon) |node| _ = node.setTint(c.fg_2);
        }
        // These parents are slots constructed by this view, not widget internals.
        if (self.notice_title.parent) |node| node.setStyleInline(self.cx.allocator, S.notice(snapshot.kind));
        if (self.key_label) |node| {
            node.setTextColor(c.fg_1);
            if (node.parent) |well| well.setStyleInline(self.cx.allocator, S.well());
        }
        if (self.fingerprint) |node| node.setTextColor(if (snapshot.kind == .host_key_changed) c.danger_ink else c.fg_2);
        if (self.previous_key_label) |node| {
            node.setTextColor(c.fg_1);
            if (node.parent) |well| well.setStyleInline(self.cx.allocator, S.well());
        }
        if (self.previous_fingerprint) |node| node.setTextColor(c.fg_2);
        if (self.private_key_path) |node| node.setTextColor(c.fg_2);
        if (self.store_path) |node| {
            node.setTextColor(c.fg_2);
            if (node.parent) |well| well.setStyleInline(self.cx.allocator, S.well());
        }
        try self.refreshState();
    }
    pub fn handleKey(self: *View, key: ui.events.KeyCode) ui.events.EventResult {
        if (!self.visible) return .ignored;
        if (self.isComposing()) return .ignored;
        switch (key) {
            .escape => self.cancel(),
            .@"return" => {
                const snapshot = self.snapshot orelse return .stop;
                // The two explicit trust actions cannot be collapsed into an
                // implicit default by a parent key handler.
                if (snapshot.kind != .host_key_unknown) self.submit();
            },
            else => return .ignored,
        }
        return .stop;
    }

    pub fn submit(self: *View) void {
        const snapshot = self.snapshot orelse return;
        if (!self.canSubmit() or self.isComposing()) return;
        if (self.otp_prefill) |proposal| if (!self.otp_edited and !proposal.validAt(self.otp_clock.now())) {
            self.clearFields();
            self.refreshState() catch {};
            return;
        };
        var answers: [auth.max_prompts][]const u8 = undefined;
        for (self.fields[0..self.field_count], 0..) |field, index| answers[index] = field.input.state.getText();
        const reply: auth.Reply = switch (snapshot.kind) {
            .host_key_unknown => .trust_save,
            .host_key_changed => .{ .replace_host_key = answers[0] },
            else => .{ .answers = answers[0..self.field_count] },
        };
        self.send(reply);
    }
    pub fn trustOnce(self: *View) void {
        const snapshot = self.snapshot orelse return;
        if (snapshot.kind != .host_key_unknown or !self.canTrustOnce()) return;
        self.send(.trust_once);
    }
    pub fn cancel(self: *View) void {
        const snapshot = self.snapshot orelse return;
        if (!self.visible or self.cancel_requested or snapshot.state == .completed or snapshot.state == .cancelled) return;
        self.cancel_requested = true;
        self.clearFields();
        self.refreshState() catch {};
        self.callbacks.cancel(self.callbacks.context, snapshot.identity);
    }

    fn send(self: *View, reply: auth.Reply) void {
        const identity = self.snapshot.?.identity;
        self.local_failure = null;
        self.pending = true;
        self.callbacks.submit(self.callbacks.context, identity, reply) catch |err| {
            self.pending = false;
            self.local_failure = err;
            if (err == error.StaleChallenge or err == error.ChallengeExpired or err == error.Cancelled) self.clearFields();
            self.refreshState() catch {};
            return;
        };
        self.clearFields();
        self.refreshState() catch {};
    }
    fn acceptsInput(self: *const View) bool {
        const snapshot = self.snapshot orelse return false;
        if (self.local_failure) |err| switch (err) {
            error.StaleChallenge, error.ChallengeExpired, error.Cancelled => return false,
            else => {},
        };
        return self.visible and !self.pending and !self.cancel_requested and
            (snapshot.state == .input or snapshot.state == .failed) and !expired(snapshot);
    }
    fn canSubmit(self: *const View) bool {
        if (!self.acceptsInput()) return false;
        const snapshot = self.snapshot.?;
        if (isHostKey(snapshot.kind)) {
            if (self.details.algorithm.len == 0 or self.details.fingerprint.len == 0) return false;
            if (snapshot.kind == .host_key_changed and (self.details.previous_algorithm.len == 0 or self.details.previous_fingerprint.len == 0 or self.details.store_path.len == 0)) return false;
            if (snapshot.kind == .host_key_changed) return self.field_count == 1 and std.mem.eql(u8, self.fields[0].input.state.getText(), "yes");
            return self.details.store_path.len != 0;
        }
        if (self.field_count == 0) return false;
        for (self.fields[0..self.field_count]) |field| {
            const value = field.input.state.getText();
            if (value.len == 0 or value.len > auth.InteractiveBridge.max_answer) return false;
        }
        return true;
    }
    fn canTrustOnce(self: *const View) bool {
        return self.acceptsInput() and self.details.algorithm.len != 0 and self.details.fingerprint.len != 0;
    }
    fn expired(snapshot: auth.Snapshot) bool {
        return snapshot.state == .expired or if (snapshot.expires_at_ns) |deadline| realtime.monotonicNs() >= deadline else false;
    }
    fn isHostKey(kind: auth.Kind) bool {
        return kind == .host_key_unknown or kind == .host_key_changed;
    }

    fn ensureModal(self: *View) !void {
        if (self.modal != null) {
            if (self.material) |material| try material.isolate(self.scope, self.modal.?.dialog);
            return;
        }
        const modal = try ui.widgets.Modal(.{ .open = ui.split(self.open, self.cx.on(View, self, openChanged)), .width = 430, .max_height = @max(160, self.cx.viewport.height - 16), .background = S.theme.current().overlay, .close_on_overlay = false }).mount(self.scope, self.cx);
        self.modal = modal;
        modal.dialog.meta.ownership.meta.test_id = "auth.challenge.modal";
        modal.body.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .fill(), .padding = .{}, .gap = 0 });
        if (!modal.portaled) if (self.cx.root) |root| try root.appendChild(self.cx.allocator, modal.overlay);
        if (self.material) |material| try material.isolate(self.scope, modal.dialog);
    }
    fn openChanged(self: *View, open: bool) void {
        if (open) return;
        // Modal dismissal precedes Input in Cx. Deliver the first composing
        // Escape to the focused editor; never interpret its post-event state.
        if (self.isComposing()) {
            if (self.cx.focus_manager.getFocused()) |focused| _ = self.cx.dispatcher.dispatchKeyDown(focused, .{ .key = .escape });
            return;
        }
        self.cancel();
    }
    fn buildForm(self: *View) !void {
        const snapshot = self.snapshot.?;
        const content_scope = try self.scope.childScope();
        self.content_scope = content_scope;
        const w = @min(S.width(snapshot.kind), @max(160, self.cx.viewport.width - 16));
        const h = @min(S.height(snapshot.kind), @max(160, self.cx.viewport.height - 16));
        const form = try ui.box(self.cx, S.form(w, h, self.inline_form), .{});
        self.form = form;
        form.meta.ownership.meta.test_id = "auth.challenge.form";
        form.behavior.events.on_event_capture = capture;
        form.behavior.events.capture_context = self;
        form.behavior.events.on_event = bubble;
        form.behavior.events.event_context = self;
        if (self.inline_form) try self.root.appendChild(self.cx.allocator, form) else {
            const modal = self.modal.?;
            modal.dialog.setStyleInline(self.cx.allocator, S.panel(w, h));
            try modal.body.appendChild(self.cx.allocator, form);
        }
        const header = try ui.box(self.cx, S.header(), .{});
        const header_icon: []const u8 = switch (snapshot.kind) {
            .password, .keyboard_interactive => "lock-keyhole",
            .host_key_unknown => "shield-question",
            .host_key_changed => "shield-alert",
            else => "key-round",
        };
        self.header_icon = try ui.iconTint(self.cx, ui.icons.get(header_icon).?, switch (snapshot.kind) {
            .host_key_unknown => S.theme.current().warn_ink,
            .host_key_changed => S.theme.current().danger_ink,
            else => S.theme.current().accent,
        }, S.icon(18));
        self.header_icon.meta.ownership.meta.test_id = "auth.challenge.title.icon";
        try header.appendChild(self.cx.allocator, self.header_icon);
        self.title = try self.label(header, titleFor(snapshot.kind), S.text(13, 700, false));
        self.title.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 20 }, .flex = 1, .min_width = 0 });
        const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "取消当前连接认证", .on_click = self.cx.on(View, self, cancel) }).mount(content_scope, self.cx);
        self.header_close = close;
        self.header_close_icon = try ui.iconTint(self.cx, ui.icons.x, S.theme.current().fg_2, S.icon(16));
        try close.appendChild(self.cx.allocator, self.header_close_icon);
        close.setStyleInline(self.cx.allocator, S.close());
        close.meta.ownership.meta.test_id = "auth.challenge.close";
        try header.appendChild(self.cx.allocator, close);
        try form.appendChild(self.cx.allocator, header);
        const body = try ui.box(self.cx, S.body(), .{});
        try form.appendChild(self.cx.allocator, body);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(content_scope, self.cx);
        scroll.container.setStyleInline(self.cx.allocator, S.scroll());
        scroll.container.meta.ownership.meta.test_id = "auth.challenge.scroll";
        scroll.content.setStyleInline(self.cx.allocator, S.stack());
        try body.appendChild(self.cx.allocator, scroll.container);
        const stack = scroll.content;
        const identity = try ui.box(self.cx, S.identity(), .{});
        self.identity_icon = try ui.iconTint(self.cx, ui.icons.server, S.theme.current().fg_2, S.icon(18));
        try identity.appendChild(self.cx.allocator, self.identity_icon);
        const identity_text = try ui.box(self.cx, S.identityText(), .{});
        self.identity_name = try self.label(identity_text, "", S.text(14, 500, false));
        self.identity_endpoint = try self.label(identity_text, "", S.text(10.5, 400, true));
        self.identity_endpoint.meta.ownership.meta.test_id = "auth.challenge.endpoint";
        try identity.appendChild(self.cx.allocator, identity_text);
        try stack.appendChild(self.cx.allocator, identity);
        self.hop = try self.label(stack, "", S.text(11, 400, false));
        self.hop.meta.ownership.meta.test_id = "auth.challenge.hop";
        if (isHostKey(snapshot.kind)) try self.addNotice(stack);
        if (snapshot.kind != .keyboard_interactive) {
            if (snapshot.kind == .host_key_changed) {
                const old = try self.addKeyWell(stack, "原密钥");
                self.previous_key_label = old.label;
                self.previous_fingerprint = old.value;
            }
            const key = try self.addKeyWell(stack, if (snapshot.kind == .host_key_changed) "新密钥" else "服务器主机密钥");
            self.key_label = key.label;
            self.fingerprint = key.value;
            if (snapshot.kind == .host_key_changed) key.value.setTextColor(S.theme.current().danger_ink);
            key.value.meta.ownership.meta.test_id = "auth.challenge.fingerprint";
        }
        switch (snapshot.kind) {
            .host_key_unknown => {
                const store = try ui.box(self.cx, S.well(), .{});
                _ = try self.label(store, "主机密钥记录", S.text(11, 500, false));
                self.store_path = try self.label(store, "尚未提供记录路径", S.text(10, 400, true));
                try stack.appendChild(self.cx.allocator, store);
                _ = try self.label(stack, "仅本次信任不会写入记录；保存并继续会记住核对的密钥。", S.text(11, 400, false));
            },
            .host_key_changed => {
                try self.addField(stack, "输入小写 yes，确认替换已保存的密钥", false, 32);
                _ = try self.label(stack, "只有完整输入 yes 后，才可替换密钥并继续连接。", S.text(10.5, 400, false));
                _ = try self.label(stack, "取消会保留原密钥记录，并取消本次连接。", S.text(11, 400, false));
            },
            else => {
                for (0..snapshot.prompt_count) |index| {
                    const prompt = snapshot.promptAt(index);
                    try self.addField(stack, prompt.text, !prompt.echo, S.field_height);
                }
                if (snapshot.kind == .private_key_passphrase) self.private_key_path = try self.label(stack, "尚未提供私钥路径", S.text(10.5, 400, true));
                try self.addNotice(stack);
            },
        }
        const actions = try ui.box(self.cx, S.footer(), .{});
        self.actions = actions;
        actions.meta.ownership.meta.test_id = "auth.challenge.actions";
        if (snapshot.kind != .host_key_unknown) try actions.appendChild(self.cx.allocator, try ui.spacer(self.cx));
        self.cancel_button = try self.action(actions, "取消连接", if (isHostKey(snapshot.kind)) 104 else 100, false, false, false, cancel, "auth.challenge.cancel");
        if (snapshot.kind == .host_key_unknown) self.trust_once_button = try self.action(actions, "仅本次信任", 132, false, false, true, trustOnce, "auth.challenge.trust_once");
        self.submit_button = try self.action(actions, submitFor(snapshot.kind), switch (snapshot.kind) {
            .host_key_unknown => 146,
            .host_key_changed => 172,
            .keyboard_interactive => 136,
            else => 142,
        }, true, snapshot.kind == .host_key_changed, true, submit, "auth.challenge.submit");
        try body.appendChild(self.cx.allocator, actions);
        try @import("compact_overlay_layout.zig").mountMirrored(self.cx, content_scope, form, scroll.container, scroll.content, 100, S.height(snapshot.kind) - 100, null, 0, if (self.inline_form) null else self.modal.?.dialog);
    }
    fn label(self: *View, parent: *ui.Node, text: []const u8, style: ui.TextStyle) !*ui.Node {
        const node = try ui.text(self.cx, text, style);
        node.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = style.font_size * style.line_height, .flex_shrink = 0 });
        try parent.appendChild(self.cx.allocator, node);
        try self.own_labels.append(self.cx.allocator, .{ .node = node, .strong = style.font_weight >= 500 });
        return node;
    }
    fn addKeyWell(self: *View, parent: *ui.Node, name: []const u8) !struct { label: *ui.Node, value: *ui.Node } {
        const well = try ui.box(self.cx, S.well(), .{});
        const label_node = try self.label(well, name, S.text(11, 500, false));
        const value = try self.label(well, "尚未提供完整指纹", S.text(10, 400, true));
        try parent.appendChild(self.cx.allocator, well);
        return .{ .label = label_node, .value = value };
    }
    fn addNotice(self: *View, parent: *ui.Node) !void {
        const notice = try ui.box(self.cx, S.notice(self.snapshot.?.kind), .{});
        self.notice_title = try self.label(notice, "", S.text(12, 500, false));
        self.notice_detail = try self.label(notice, "", S.text(11, 400, false));
        self.notice_detail.meta.ownership.meta.test_id = "auth.challenge.status";
        self.notice_detail.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
        try parent.appendChild(self.cx.allocator, notice);
    }
    fn addField(self: *View, parent: *ui.Node, prompt: []const u8, secret: bool, h: f32) !void {
        if (self.field_count == auth.max_prompts) return error.InvalidChallengePrompt;
        const field = &self.fields[self.field_count];
        const wrapper = try ui.box(self.cx, S.field(), .{});
        _ = try self.label(wrapper, prompt, S.text(11, 500, false));
        field.* = .{ .view = self, .secret = secret, .input = undefined };
        const input_type: ui.widgets.input.InputType = if (secret) .password else .text;
        field.input = try ui.widgets.Input(.{ .input_type = input_type, .disabled = self.disabled, .on_change = self.cx.on(Field, field, Field.changed), .on_submit = self.cx.on(Field, field, Field.submit) }).mountResult(self.content_scope.?, self.cx);
        field.input.node.setStyleInline(self.cx.allocator, S.inputWrapper(h));
        field.input.input_container.setStyleInline(self.cx.allocator, S.input(h, secret));
        S.tuneInput(&field.input);
        field.input.input_container.meta.ownership.meta.test_id = try std.fmt.bufPrint(&field.id, "auth.challenge.answer.{d}", .{self.field_count});
        const control = try ui.box(self.cx, S.inputWrapper(h), .{});
        try control.appendChild(self.cx.allocator, field.input.node);
        try wrapper.appendChild(self.cx.allocator, control);
        if (secret) {
            const eye = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "显示认证输入", .disabled = self.disabled, .on_click = self.cx.on(Field, field, Field.reveal) }).mount(self.content_scope.?, self.cx);
            field.eye_icon = try ui.iconTint(self.cx, ui.icons.get("eye").?, S.theme.current().fg_2, S.icon(16));
            try eye.appendChild(self.cx.allocator, field.eye_icon.?);
            eye.setStyleInline(self.cx.allocator, S.eye(h));
            eye.meta.ownership.meta.test_id = try std.fmt.bufPrint(&field.eye_id, "auth.challenge.reveal.{d}", .{self.field_count});
            field.eye = eye;
            try control.appendChild(self.cx.allocator, eye);
        }
        self.field_count += 1;
        try parent.appendChild(self.cx.allocator, wrapper);
    }
    fn action(self: *View, parent: *ui.Node, text: []const u8, w: f32, primary: bool, danger: bool, gated: bool, comptime callback: *const fn (*View) void, id: []const u8) !*ui.Node {
        const gate: ui.Source(bool) = if (gated) .{ .signal = if (std.mem.eql(u8, id, "auth.challenge.trust_once")) self.trust_disabled else self.submit_disabled } else .{ .value = false };
        const variant: ui.widgets.button.ButtonVariant = if (danger) .danger else if (primary) .primary else .secondary;
        const button = try ui.widgets.Button(.{ .variant = variant, .a11y_label = text, .disabled = gate, .on_click = self.cx.on(View, self, callback) }).mount(self.content_scope.?, self.cx);
        button.setStyleInline(self.cx.allocator, S.button(w, primary, danger));
        button.meta.ownership.meta.test_id = id;
        const text_style = S.actionText(primary);
        const label_node = try ui.text(self.cx, text, text_style);
        try button.appendChild(self.cx.allocator, label_node);
        if (primary) self.submit_label = label_node;
        if (std.mem.eql(u8, id, "auth.challenge.cancel")) self.cancel_label = label_node;
        if (std.mem.eql(u8, id, "auth.challenge.trust_once")) self.trust_once_label = label_node;
        try parent.appendChild(self.cx.allocator, button);
        return button;
    }
    fn refreshDetails(self: *View) !void {
        const snapshot = self.snapshot orelse return;
        var buffer: [2048]u8 = undefined;
        const endpoint = snapshot.endpoint();
        try self.identity_name.setTextContent(self.cx.allocator, if (self.details.display_name.len != 0) self.details.display_name else endpoint.host);
        try self.identity_endpoint.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "{s}@{s}:{d}", .{ endpoint.user, endpoint.host, endpoint.port }));
        try self.hop.setTextContent(self.cx.allocator, if (self.details.route_label.len != 0) try std.fmt.bufPrint(&buffer, "第 {d} 跳 · {s}", .{ snapshot.identity.hop_index + 1, self.details.route_label }) else try std.fmt.bufPrint(&buffer, "第 {d} 跳", .{snapshot.identity.hop_index + 1}));
        if (self.key_label) |node| try node.setTextContent(self.cx.allocator, if (self.details.algorithm.len != 0) self.details.algorithm else "服务器主机密钥 · 算法未知");
        if (self.fingerprint) |node| try node.setTextContent(self.cx.allocator, if (self.details.fingerprint.len != 0) self.details.fingerprint else "尚未提供完整指纹");
        if (self.previous_key_label) |node| try node.setTextContent(self.cx.allocator, if (self.details.previous_algorithm.len != 0) self.details.previous_algorithm else "原密钥 · 算法未知");
        if (self.previous_fingerprint) |node| try node.setTextContent(self.cx.allocator, if (self.details.previous_fingerprint.len != 0) self.details.previous_fingerprint else "尚未提供原密钥完整指纹");
        if (self.private_key_path) |node| try node.setTextContent(self.cx.allocator, if (self.details.private_key_path.len != 0) self.details.private_key_path else "尚未提供私钥路径");
        if (self.store_path) |node| try node.setTextContent(self.cx.allocator, if (self.details.store_path.len != 0) self.details.store_path else "尚未提供记录路径");
    }
    fn refreshState(self: *View) !void {
        const snapshot = self.snapshot orelse return;
        const focused = self.cx.focus_manager.getFocused();
        var input_had_focus = false;
        for (self.fields[0..self.field_count]) |field| if (focused == field.input.input_container) {
            input_had_focus = true;
        };
        if (expired(snapshot) or snapshot.state == .completed or snapshot.state == .cancelled) self.clearFields();
        self.disabled.set(!self.acceptsInput());
        self.submit_disabled.set(!self.canSubmit());
        self.trust_disabled.set(!self.canTrustOnce());
        // These labels are our public Button children. Its disabled source
        // gates interaction, while this view owns their painted foreground.
        self.paintAction(self.submit_label, true, self.submit_disabled.peek());
        if (self.trust_once_label) |node| self.paintAction(node, false, self.trust_disabled.peek());
        // Disabling Input revokes its focus. Keep cancellation keyboard
        // reachable while awaiting authentication/expiry/release receipts.
        if (self.visible and !self.acceptsInput() and input_had_focus) self.cx.setFocus(self.cancel_button);
        var title: []const u8 = switch (snapshot.kind) {
            .password => "需要登录密码",
            .private_key_passphrase => "需要解锁私钥",
            .keyboard_interactive => "需要追加认证",
            .host_key_unknown => "首次连接，尚未信任此主机",
            .host_key_changed => "服务器密钥与已保存记录不同",
        };
        var detail: []const u8 = switch (snapshot.kind) {
            .password, .private_key_passphrase => "凭据仅用于当前认证；取消会停止本次连接。",
            .keyboard_interactive => "请按服务器提示填写；填写后仍需提交。",
            .host_key_unknown => "请通过可信渠道核对服务器指纹后，再决定是否继续。",
            .host_key_changed => "这可能是服务器重装，也可能是连接被冒充。请先核对新指纹。",
        };
        if (self.cancel_requested) {
            title = "正在取消连接";
            detail = "等待本次连接的资源释放结果。";
        } else if (expired(snapshot)) {
            title = "本次认证已到期";
            detail = "旧输入已清空，等待服务器发起下一次认证。";
        } else if (self.local_failure != null or snapshot.state == .failed) {
            title = if (isHostKey(snapshot.kind)) "主机密钥确认失败" else "认证未通过";
            detail = if (isHostKey(snapshot.kind)) "请核对密钥与记录路径后重试，或取消本次连接。" else "请核对当前连接的认证信息后重新填写。";
        } else switch (snapshot.state) {
            .submitting => {
                title = "正在提交认证";
                detail = "正在等待当前连接的认证结果。";
            },
            .completed => {
                title = "本次认证已完成";
                detail = "等待当前连接继续。";
            },
            .cancelled => {
                title = "本次认证已取消";
                detail = "等待本次连接的资源释放结果。";
            },
            else => if (self.pending) {
                title = "正在提交认证";
                detail = "正在等待当前连接的认证结果。";
            },
        }
        try self.notice_title.setTextContent(self.cx.allocator, title);
        try self.notice_detail.setTextContent(self.cx.allocator, detail);
        const failure = self.local_failure != null or snapshot.state == .failed or expired(snapshot);
        self.notice_title.setTextColor(if (failure) S.theme.current().danger_ink else S.theme.current().fg_1);
        try self.submit_label.setTextContent(self.cx.allocator, if (self.pending or snapshot.state == .submitting) "正在提交…" else submitFor(snapshot.kind));
        self.cx.requestRedraw();
    }
    fn paintAction(self: *View, node: *ui.Node, primary: bool, disabled: bool) void {
        const color = S.actionColor(primary, disabled);
        node.setTextColor(color);
        node.setStyle(self.cx.allocator, .text_color, color);
    }
    fn clearFields(self: *View) void {
        if (self.otp_prefill) |*proposal| proposal.deinit();
        self.otp_prefill = null;
        self.otp_edited = false;
        for (self.fields[0..self.field_count]) |*field| {
            field.input.state.applyExternalText("") catch {};
            if (field.secret) {
                field.revealed = false;
                field.input.state.input_type = .password;
                field.input.state.dirty = true;
            }
        }
    }
    fn clearForm(self: *View) void {
        if (self.content_scope) |scope| scope.dispose();
        self.content_scope = null;
        if (self.form) |node| {
            if (node.parent) |parent| self.cx.detachChild(parent, node);
            self.cx.freeNode(node);
        }
        self.form = null;
        self.field_count = 0;
        self.own_labels.clearRetainingCapacity();
        self.key_label = null;
        self.fingerprint = null;
        self.previous_key_label = null;
        self.previous_fingerprint = null;
        self.private_key_path = null;
        self.store_path = null;
        self.trust_once_button = null;
        self.trust_once_label = null;
    }
    fn clearDetails(self: *View) void {
        if (self.details_arena) |*arena| arena.deinit();
        self.details_arena = null;
        self.details = .{};
    }
    fn cleanup(self: *View) void {
        // Child widget scopes have already been disposed; never dereference
        // their input states here. hide() clears responses before normal exit.
        self.clearDetails();
        self.own_labels.deinit(self.cx.allocator);
        self.cx.allocator.destroy(self);
    }
    fn capture(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event == .key_down and event.key_down.key == .escape) return self.handleKey(.escape);
        return .ignored;
    }
    fn bubble(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        if (!self.visible) return .ignored;
        // Input receives text, composition and shortcuts first. Anything it
        // leaves unhandled remains inside this form rather than reaching VT.
        // Never reinterpret the same key here: Input may have just cancelled
        // composition, so its post-event isComposing=false cannot authorize a
        // second Escape action. Explicit Enter belongs to Input.on_submit.
        return switch (event) {
            .key_down, .key_up, .text_input, .ime_preedit, .ime_commit => .stop,
            else => .ignored,
        };
    }
    fn titleFor(kind: auth.Kind) []const u8 {
        return switch (kind) {
            .password => "SSH 密码认证",
            .private_key_passphrase => "解锁 SSH 私钥",
            .keyboard_interactive => "SSH 追加认证",
            .host_key_unknown => "核对主机密钥",
            .host_key_changed => "主机密钥已变更",
        };
    }
    fn submitFor(kind: auth.Kind) []const u8 {
        return switch (kind) {
            .password => "认证并继续",
            .private_key_passphrase => "解锁并继续",
            .keyboard_interactive => "验证并继续",
            .host_key_unknown => "保存并继续",
            .host_key_changed => "替换密钥并继续",
        };
    }
};
