//! Real widget/InteractiveBridge contract tests; no window or network.
const std = @import("std");
const ui = @import("ui");
const module = @import("ui/auth_challenge_view.zig");
const auth = module.auth;
const a = std.testing.allocator;
const theme = @import("ui/app_theme.zig");

test "idle authentication hide clears secrets once without requesting another frame" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.offer(.keyboard_interactive, .protected_form, &.{.{ .text = "Password:", .echo = false }});
    f.edit(0, "temporary secret");
    f.view.hide();
    try std.testing.expectEqualStrings("", f.view.fields[0].input.state.getText());
    f.cx.needs_redraw = false;
    f.view.hide();
    try std.testing.expect(!f.cx.needs_redraw);
    try std.testing.expectEqual(@as(usize, 0), f.cancelled);
}

fn expectPaintedLabel(cx: *ui.Cx, label: *ui.Node, expected: ui.Color) !void {
    try cx.setTestFrameStep(100);
    for (0..4) |_| {
        cx.requestRedraw();
        cx.advanceFrameClock();
        _ = cx.render();
    }
    try std.testing.expectEqual(expected, label.resolveTextColor() orelse label.getText().?.color);
    var found = false;
    for (cx.render()) |item| switch (item) {
        .text_run => |run| if (std.mem.eql(u8, run.content, label.getText().?.content)) {
            try std.testing.expectEqual(expected, run.color);
            found = true;
        },
        else => {},
    };
    try std.testing.expect(found);
}

const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *module.View,
    bridge: auth.InteractiveBridge = .{},
    submitted: usize = 0,
    cancelled: usize = 0,
    leaked_input: usize = 0,
    replacement_confirmed: bool = false,
    reject_submit: ?anyerror = null,
    callback_identity: ?auth.RequestIdentity = null,
    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .view = undefined };
        self.cx.setViewport(1440, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        self.cx.root.?.behavior.events.on_event = recordLeak;
        self.cx.root.?.behavior.events.event_context = self;
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.view = try module.View.mount(self.cx, self.scope, .{ .context = self, .submit = submit, .cancel = cancel });
        try self.cx.root.?.appendChild(a, self.view.root);
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
    }
    fn offer(self: *Fixture, kind: auth.Kind, presentation: auth.Presentation, prompts: []const auth.Prompt) !auth.RequestIdentity {
        const id = try self.bridge.offerChallenge(.{
            .key = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(9), .generation = 3 } }, .operation_id = 7, .attempt_id = 2 },
            .hop_index = 1,
            .kind = kind,
            .endpoint_identity = .{ .host = "target.example", .user = "operator", .port = 2222 },
            .prompts = prompts,
            .presentation = presentation,
            .presentation_config_revision = 4,
        });
        try self.view.show(self.bridge.snapshot().?);
        self.cx.layout();
        return id;
    }
    fn submit(raw: *anyopaque, id: auth.RequestIdentity, reply: auth.Reply) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.reject_submit) |err| return err;
        try self.bridge.submit(id, reply);
        if (reply == .replace_host_key) self.replacement_confirmed = std.mem.eql(u8, reply.replace_host_key, "yes");
        self.submitted += 1;
        self.callback_identity = id;
    }
    fn cancel(raw: *anyopaque, id: auth.RequestIdentity) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.bridge.cancelRequest(id)) self.cancelled += 1;
        self.callback_identity = id;
    }
    fn edit(self: *Fixture, index: usize, text: []const u8) void {
        self.cx.layout();
        self.cx.setFocus(self.view.fields[index].input.input_container);
        self.cx.handleTextInput(text);
    }
    fn recordLeak(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        switch (event) {
            .key_down, .key_up, .text_input, .ime_preedit, .ime_commit => self.leaked_input += 1,
            else => {},
        }
        return .ignored;
    }
};

test "auth challenge view protected form orders real inputs and submits the original request once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.offer(.keyboard_interactive, .protected_form, &.{ .{ .text = "Account:", .echo = true }, .{ .text = "Recovery phrase:", .echo = false } });
    try std.testing.expect(f.view.isInline());
    try std.testing.expect(f.view.modal == null);
    try std.testing.expectEqualStrings("Account:", f.view.snapshot.?.promptAt(0).text);
    try std.testing.expectEqualStrings("operator@target.example:2222", f.view.identity_endpoint.getText().?.content);
    try std.testing.expectEqualStrings("第 2 跳", f.view.hop.getText().?.content);
    try std.testing.expectEqual(ui.widgets.input.InputType.text, f.view.fields[0].input.state.input_type);
    try std.testing.expectEqual(ui.widgets.input.InputType.password, f.view.fields[1].input.state.input_type);
    f.edit(0, "operator");
    f.edit(1, "arbitrary recovery phrase");
    const first_input = f.view.fields[0].input.state;
    var same = f.bridge.snapshot().?;
    same.presentation = .otp_modal;
    same.presentation_config_revision = 999;
    try f.view.show(same);
    try std.testing.expect(f.view.isInline());
    try std.testing.expect(f.view.modal == null);
    try std.testing.expectEqual(first_input, f.view.fields[0].input.state);
    try std.testing.expectEqualStrings("arbitrary recovery phrase", f.view.fields[1].input.state.getText());
    f.cx.handleKeyDown(.@"return", .{});
    f.cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(@as(usize, 1), f.submitted);
    try std.testing.expect(f.callback_identity.?.eql(id));
    try std.testing.expectEqual(@as(usize, 0), f.leaked_input);
    try std.testing.expect(f.view.submit_disabled.peek());
    try std.testing.expectEqualStrings("", f.view.fields[1].input.state.getText());
    var result = try f.bridge.waitResponse(id, 50);
    defer result.deinit();
    try std.testing.expectEqualStrings("operator", result.answerAt(0));
    try std.testing.expectEqualStrings("arbitrary recovery phrase", result.answerAt(1));
    f.cx.handleKeyDown(.escape, .{});
    try std.testing.expectEqual(@as(usize, 1), f.cancelled);
    try std.testing.expect(f.callback_identity.?.eql(id));
}

test "auth challenge view five kinds use exact modal dimensions and generic prompts keep their format" {
    const S = @import("ui/auth_challenge_styles.zig");
    for (std.enums.values(auth.Kind)) |kind| {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        _ = try f.offer(kind, .otp_modal, if (kind == .host_key_unknown or kind == .host_key_changed) &.{} else &.{.{ .text = "Server prompt", .echo = false }});
        try std.testing.expect(!f.view.isInline());
        try std.testing.expectEqual(S.width(kind), f.view.modal.?.dialog.style.width.px);
        try std.testing.expect(f.view.modal.?.dialog.style.height.px <= S.height(kind));
        try std.testing.expectEqual(S.width(kind), f.view.modal.?.dialog.globalRect().w);
        try std.testing.expect(f.view.modal.?.dialog.globalRect().h <= S.height(kind));
        try std.testing.expectEqual(@as(f32, 34), f.view.actions.globalRect().h);
        try std.testing.expectApproxEqAbs(f.view.modal.?.dialog.globalRect().y + f.view.modal.?.dialog.globalRect().h - 12, f.view.actions.globalRect().y + 34, 0.01);
        if (kind == .keyboard_interactive) {
            f.edit(0, "not a six digit code");
            try std.testing.expect(!f.view.submit_disabled.peek());
        }
    }
}

test "auth challenge view unknown host requires real details and keeps once versus saved decisions distinct" {
    for ([_]bool{ false, true }) |save| {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const id = try f.offer(.host_key_unknown, .protected_form, &.{});
        f.view.submit();
        f.view.trustOnce();
        try std.testing.expectEqual(@as(usize, 0), f.submitted);
        try f.view.setDetails(id, .{ .algorithm = "ssh-ed25519", .fingerprint = "SHA256:verified-full-fingerprint", .store_path = if (save) "/tmp/known_hosts" else "" });
        try std.testing.expectEqual(!save, f.view.submit_disabled.peek());
        try std.testing.expect(!f.view.trust_disabled.peek());
        _ = f.view.handleKey(.@"return");
        try std.testing.expectEqual(@as(usize, 0), f.submitted);
        if (save) {
            f.reject_submit = error.PermissionDenied;
            f.view.submit();
            try std.testing.expectEqual(@as(usize, 0), f.submitted);
            try std.testing.expectEqualStrings("主机密钥确认失败", f.view.notice_title.getText().?.content);
            try std.testing.expect(!f.view.pending);
            f.reject_submit = null;
            f.view.submit();
            f.view.submit();
        } else {
            f.view.trustOnce();
            f.view.trustOnce();
        }
        try std.testing.expectEqual(@as(usize, 1), f.submitted);
        try std.testing.expectEqualStrings("正在提交认证", f.view.notice_title.getText().?.content);
        var response = try f.bridge.waitResponse(id, 50);
        defer response.deinit();
        try std.testing.expectEqual(if (save) @as(@TypeOf(response.decision), .trust_save) else .trust_once, response.decision);
    }
}

test "auth challenge view first enable paints the actual primary label without retheme" {
    const previous_theme = theme.currentName();
    defer theme.select(previous_theme);
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        for ([_]auth.Kind{ .host_key_unknown, .password }) |kind| {
            var f: Fixture = undefined;
            try f.init();
            defer f.deinit();
            f.cx.setTheme(theme.widgetTheme(name));
            const id = try f.offer(kind, .protected_form, if (kind == .host_key_unknown) &.{} else &.{.{ .text = "Password:", .echo = false }});
            try std.testing.expect(f.view.submit_disabled.peek());
            try expectPaintedLabel(f.cx, f.view.submit_label, theme.current().fg_3);
            if (kind == .host_key_unknown) {
                try f.view.setDetails(id, .{ .algorithm = "ssh-ed25519", .fingerprint = "SHA256:verified-full-fingerprint", .store_path = "/tmp/known_hosts" });
            } else {
                f.edit(0, "first secret");
            }
            try std.testing.expect(!f.view.submit_disabled.peek());
            try std.testing.expect(!f.view.submit_button.behavior.interaction.a11y.?.disabled);
            try expectPaintedLabel(f.cx, f.view.submit_label, ui.Color.WHITE);
            f.view.submit();
            try std.testing.expectEqual(@as(usize, 1), f.submitted);
            try std.testing.expect(f.view.submit_disabled.peek());
            try expectPaintedLabel(f.cx, f.view.submit_label, theme.current().fg_3);
        }
    }
}

test "auth challenge view error retry expiry and cancellation never replay old secrets" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.offer(.password, .protected_form, &.{.{ .text = "Password:", .echo = false }});
    f.edit(0, "first secret");
    f.view.submit();
    var result = try f.bridge.waitResponse(id, 50);
    result.deinit();
    const retry = try f.bridge.reject(id, error.AuthenticationFailed);
    try f.view.show(f.bridge.snapshot().?);
    try std.testing.expectEqualStrings("", f.view.fields[0].input.state.getText());
    try std.testing.expectEqualStrings("认证未通过", f.view.notice_title.getText().?.content);
    try std.testing.expectError(error.StaleChallenge, f.view.setDetails(id, .{ .display_name = "wrong owner" }));
    f.edit(0, "second secret");
    var expired = f.bridge.snapshot().?;
    expired.state = .expired;
    try f.view.show(expired);
    try std.testing.expectEqualStrings("", f.view.fields[0].input.state.getText());
    try std.testing.expect(f.view.submit_disabled.peek());
    f.view.submit();
    try std.testing.expectEqual(@as(usize, 1), f.submitted);
    f.view.cancel();
    f.view.cancel();
    try std.testing.expectEqual(@as(usize, 1), f.cancelled);
    try std.testing.expect(f.callback_identity.?.eql(retry));
    try std.testing.expectEqualStrings("正在取消连接", f.view.notice_title.getText().?.content);
}

test "auth challenge view host key details are copied and replacement needs exact lowercase yes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.offer(.host_key_changed, .protected_form, &.{});
    try std.testing.expect(f.view.submit_disabled.peek());
    var fingerprint = "SHA256:actual-new-key".*;
    try f.view.setDetails(id, .{ .algorithm = "ssh-ed25519", .fingerprint = &fingerprint, .previous_algorithm = "ssh-rsa", .previous_fingerprint = "SHA256:actual-old-key", .store_path = "/tmp/known_hosts" });
    @memset(&fingerprint, 'x');
    try std.testing.expectEqualStrings("SHA256:actual-new-key", f.view.fingerprint.?.getText().?.content);
    f.edit(0, "YES");
    try std.testing.expect(f.view.submit_disabled.peek());
    f.view.fields[0].input.state.applyExternalText("") catch unreachable;
    f.edit(0, "yes");
    try std.testing.expect(!f.view.submit_disabled.peek());
    f.view.submit();
    var response = try f.bridge.waitResponse(id, 50);
    defer response.deinit();
    try std.testing.expectEqual(.replace_host_key, response.decision);
    try std.testing.expect(f.replacement_confirmed);
    try std.testing.expectEqual(@as(usize, 0), response.count);
}

test "auth challenge view composition consumes Enter before explicit submit and escape cancels only after composition" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.offer(.keyboard_interactive, .protected_form, &.{.{ .text = "Response:", .echo = true }});
    f.cx.setFocus(f.view.fields[0].input.input_container);
    f.cx.handleImePreedit("pin", 3);
    try std.testing.expect(f.view.isComposing());
    try std.testing.expectEqual(ui.events.EventResult.ignored, f.view.handleKey(.@"return"));
    try std.testing.expectEqual(ui.events.EventResult.ignored, f.view.handleKey(.escape));
    try std.testing.expectEqual(@as(usize, 0), f.submitted);
    try std.testing.expectEqual(@as(usize, 0), f.cancelled);
    f.cx.handleKeyDown(.escape, .{});
    try std.testing.expect(!f.view.isComposing());
    try std.testing.expectEqual(@as(usize, 0), f.cancelled);
    f.cx.handleImePreedit("pin", 3);
    f.cx.handleImeCommit("拼");
    try std.testing.expect(!f.view.isComposing());
    f.cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(@as(usize, 1), f.submitted);
    try std.testing.expectEqual(@as(usize, 0), f.leaked_input);
}

test "auth challenge visible modal trust button receives actual pointer below a long scroll body" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.offer(.host_key_unknown, .otp_modal, &.{});
    try f.view.setDetails(id, .{ .algorithm = "ecdsa-sha2-nistp256", .fingerprint = "SHA256:actual-key", .store_path = "/var/folders/hb/12753xs57vs9vv2xpy73kcn80000gn/T/zerowork-inline-current-original/data/known_hosts" });
    try f.cx.setTestFrameStep(100);
    for (0..8) |_| {
        f.cx.requestRedraw();
        f.cx.advanceFrameClock();
        _ = f.cx.render();
    }
    const rect = f.view.trust_once_button.?.globalRect();
    f.cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
    f.cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
    try std.testing.expectEqual(@as(usize, 1), f.submitted);
}

test "auth challenge visible file modal receives pointer after a probe modal hides" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const Conflict = @import("ui/transfer_conflict_view.zig");
    const Callbacks = struct {
        fn decide(_: *anyopaque, _: Conflict.Conflict.Request) !void {}
        fn postpone(_: *anyopaque, _: Conflict.domain.Key) !void {}
    };
    _ = try Conflict.View.mount(f.cx, f.scope, .{ .context = &f, .decision = Callbacks.decide, .defer_conflict = Callbacks.postpone });
    const id = try f.offer(.host_key_unknown, .otp_modal, &.{});
    try f.view.setDetails(id, .{ .algorithm = "ssh-ed25519", .fingerprint = "SHA256:probe", .store_path = "/tmp/probe/known_hosts" });
    try f.cx.setTestFrameStep(100);
    for (0..8) |_| {
        f.cx.requestRedraw();
        f.cx.advanceFrameClock();
        _ = f.cx.render();
    }
    f.view.hide();
    for (0..8) |_| {
        f.cx.requestRedraw();
        f.cx.advanceFrameClock();
        _ = f.cx.render();
    }
    f.view = try module.View.mount(f.cx, f.scope, .{ .context = &f, .submit = Fixture.submit, .cancel = Fixture.cancel });
    try f.cx.root.?.appendChild(a, f.view.root);
    try f.view.show(f.bridge.snapshot().?);
    try f.view.setDetails(id, .{ .algorithm = "ssh-ed25519", .fingerprint = "SHA256:file", .store_path = "/var/folders/hb/12753xs57vs9vv2xpy73kcn80000gn/T/zerowork-inline-current-original/data/known_hosts" });
    for (0..8) |_| {
        f.cx.requestRedraw();
        f.cx.advanceFrameClock();
        _ = f.cx.render();
    }
    const rect = f.view.trust_once_button.?.globalRect();
    f.cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
    f.cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
    try std.testing.expectEqual(@as(usize, 1), f.submitted);
}

test "auth password eye receives real pointer without submitting or changing secret value" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.offer(.password, .otp_modal, &.{.{ .text = "Password:", .echo = false }});
    f.edit(0, "local-fixture-secret");
    f.cx.layout();
    const eye = f.view.fields[0].eye.?;
    const input = f.view.fields[0].input;
    try std.testing.expect(eye.parent != input.node);
    var bounds = eye.globalRect();
    f.cx.handleClick(bounds.x + bounds.w / 2, bounds.y + bounds.h / 2);
    f.cx.handleMouseUp(bounds.x + bounds.w / 2, bounds.y + bounds.h / 2);
    try std.testing.expectEqual(ui.widgets.input.InputType.text, input.state.input_type);
    try std.testing.expectEqualStrings("local-fixture-secret", input.state.getText());
    try std.testing.expectEqualStrings("隐藏认证输入", eye.behavior.interaction.a11y.?.label.?);
    f.cx.layout();
    bounds = eye.globalRect();
    f.cx.handleClick(bounds.x + bounds.w / 2, bounds.y + bounds.h / 2);
    f.cx.handleMouseUp(bounds.x + bounds.w / 2, bounds.y + bounds.h / 2);
    try std.testing.expectEqual(ui.widgets.input.InputType.password, input.state.input_type);
    try std.testing.expectEqual(@as(usize, 0), f.submitted);
    try std.testing.expectEqual(@as(usize, 0), f.cancelled);
}

test "auth challenge semantic title icons distinguish secrets from trust and keep warning colors after retheme" {
    defer theme.select(.dark);
    for (std.enums.values(auth.Kind)) |kind| {
        theme.select(.dark);
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        _ = try f.offer(kind, .otp_modal, if (kind == .host_key_unknown or kind == .host_key_changed) &.{} else &.{.{ .text = "Fixture prompt", .echo = false }});
        const asset = switch (kind) {
            .password, .keyboard_interactive => ui.icons.lock_keyhole,
            .private_key_passphrase => ui.icons.key_round,
            .host_key_unknown => ui.icons.shield_question,
            .host_key_changed => ui.icons.shield_alert,
        };
        try std.testing.expectEqual(asset.icon_id.?, f.view.header_icon.getIcon().?.icon_id);
        for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
            theme.select(name);
            f.cx.setTheme(theme.widgetTheme(name));
            try f.view.retheme();
            const colors = theme.current();
            const tint = switch (kind) {
                .host_key_unknown => colors.warn_ink,
                .host_key_changed => colors.danger_ink,
                else => colors.accent,
            };
            try std.testing.expectEqual(tint, f.view.header_icon.getIcon().?.tint);
            try std.testing.expectEqual(colors.fg_1, f.view.title.getText().?.color);
        }
    }
}
