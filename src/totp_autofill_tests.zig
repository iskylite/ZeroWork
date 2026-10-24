//! Saved TOTP policy and the real Input/InteractiveBridge; no network/window.
const std = @import("std");
const ui = @import("ui");
const auth = @import("proto/ssh/auth_challenge.zig");
const prefill = @import("proto/ssh/totp_prefill.zig");
const prompt = @import("proto/ssh/auth_prompt.zig");
const View = @import("ui/auth_challenge_view.zig").View;
const hosts = @import("config/hosts.zig");
const sessions = @import("host/session_host.zig");
const a = std.testing.allocator;
const seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
const original: hosts.HostConfig = .{ .connection_id = @fromBackingInt(31), .revision = 7, .name = "Original hop", .host = "hop.example", .user = "operator", .port = 2222, .totp_secret = seed };
const key: sessions.OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(9), .generation = 3 } }, .operation_id = 7, .attempt_id = 2 };
const at59: prefill.Time = .{ .unix_seconds = 59, .monotonic_ns = 10 };

fn offer(bridge: *auth.InteractiveBridge, presentation: auth.Presentation, prompts: []const auth.Prompt) !auth.RequestIdentity {
    return bridge.offerChallenge(.{ .key = key, .source_owner = original.owner(), .hop_index = 0, .kind = .keyboard_interactive, .endpoint_identity = .{ .host = original.host, .user = original.user, .port = original.port }, .prompts = prompts, .presentation = presentation, .presentation_config_revision = 8 });
}
fn otp(bridge: *auth.InteractiveBridge) !auth.RequestIdentity {
    return offer(bridge, .otp_modal, &.{.{ .text = "Verification code:", .kind = .one_time_code }});
}
fn proposal(bridge: *auth.InteractiveBridge, id: auth.RequestIdentity, time: prefill.Time) !prefill.Suggestion {
    const snapshot = bridge.snapshot().?;
    return (try prefill.suggest(&snapshot, id, original, true, time)).?;
}

const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *View,
    bridge: auth.InteractiveBridge = .{},
    time: prefill.Time = at59,
    submitted: usize = 0,
    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .view = undefined };
        self.cx.setViewport(1440, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.view = try View.mount(self.cx, self.scope, .{ .context = self, .submit = submit, .cancel = cancel });
        try self.cx.root.?.appendChild(a, self.view.root);
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
    }
    fn now(raw: ?*anyopaque) prefill.Time {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        return self.time;
    }
    fn clock(self: *Fixture) prefill.Clock {
        return .{ .context = self, .read = now };
    }
    fn show(self: *Fixture) !auth.RequestIdentity {
        const id = try otp(&self.bridge);
        try self.view.show(self.bridge.snapshot().?);
        self.cx.layout();
        return id;
    }
    fn fill(self: *Fixture, id: auth.RequestIdentity) !bool {
        var value = try proposal(&self.bridge, id, self.time);
        defer value.deinit();
        return self.view.prefillOtp(value, self.clock());
    }
    fn submit(raw: *anyopaque, id: auth.RequestIdentity, reply: auth.Reply) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try self.bridge.submit(id, reply);
        self.submitted += 1;
    }
    fn cancel(raw: *anyopaque, id: auth.RequestIdentity) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        _ = self.bridge.cancelRequest(id);
    }
    fn edit(self: *Fixture, text: []const u8) void {
        self.cx.setFocus(self.view.fields[0].input.input_container);
        self.view.fields[0].input.state.selectAll();
        self.cx.handleTextInput(text);
    }
};

test "TOTP autofill classifies only dedicated non echo OTP labels and freezes type" {
    for ([_][]const u8{ "OTP:", "TOTP", "Verification code: ", "One-time password:", "动态验证码" }) |text| {
        try std.testing.expectEqual(prompt.Kind.one_time_code, prompt.classify(text, false));
        try std.testing.expectEqual(prompt.Kind.generic, prompt.classify(text, true));
    }
    for ([_][]const u8{ "Password:", "Password and OTP:", "Recovery code:", "Enter any response:", "Verification code or password:", "Token PIN:" }) |text| try std.testing.expectEqual(prompt.Kind.generic, prompt.classify(text, false));
    var bridge: auth.InteractiveBridge = .{};
    var prompts = [_]auth.Prompt{.{ .text = "OTP", .kind = .one_time_code }};
    _ = try offer(&bridge, .otp_modal, &prompts);
    prompts[0].kind = .generic;
    prompts[0].text = "Password";
    const frozen = bridge.snapshot().?;
    try std.testing.expectEqual(auth.PromptKind.one_time_code, frozen.promptAt(0).kind);
    try std.testing.expectEqualStrings("OTP", frozen.promptAt(0).text);
}

test "TOTP autofill respects saved switch frozen endpoint owner hop and request generation" {
    var bridge: auth.InteractiveBridge = .{};
    const id = try otp(&bridge);
    const snapshot = bridge.snapshot().?;
    try std.testing.expect(try prefill.suggest(&snapshot, id, original, false, at59) == null);
    var value = (try prefill.suggest(&snapshot, id, original, true, at59)).?;
    defer value.deinit();
    try std.testing.expectEqualStrings("287082", value.code.slice());
    try std.testing.expect(id.eql(value.identity));
    inline for (.{ "host", "user" }) |field| {
        var changed = original;
        @field(changed, field) = "different";
        try std.testing.expect(try prefill.suggest(&snapshot, id, changed, true, at59) == null);
    }
    var changed = original;
    changed.revision += 1;
    try std.testing.expect(try prefill.suggest(&snapshot, id, changed, true, at59) == null);
    changed = original;
    changed.port += 1;
    try std.testing.expect(try prefill.suggest(&snapshot, id, changed, true, at59) == null);
    changed = original;
    changed.totp_secret = null;
    try std.testing.expect(try prefill.suggest(&snapshot, id, changed, true, at59) == null);
    var stale = id;
    stale.hop_index += 1;
    try std.testing.expect(try prefill.suggest(&snapshot, stale, original, true, at59) == null);
    stale = id;
    stale.key.owner.session.generation += 1;
    try std.testing.expect(try prefill.suggest(&snapshot, stale, original, true, at59) == null);
    stale = id;
    stale.request_id += 1;
    try std.testing.expect(try prefill.suggest(&snapshot, stale, original, true, at59) == null);
}

test "TOTP autofill refuses protected mixed generic echo password and host key challenges" {
    for ([_]auth.Presentation{ .protected_form, .otp_modal }) |presentation| {
        for ([_][]const auth.Prompt{
            &.{.{ .text = "OTP", .kind = .one_time_code }},
            &.{.{ .text = "OTP" }},
            &.{.{ .text = "OTP", .kind = .one_time_code, .echo = true }},
            &.{ .{ .text = "Password" }, .{ .text = "OTP", .kind = .one_time_code } },
        }, 0..) |prompts, index| {
            var bridge: auth.InteractiveBridge = .{};
            const id = try offer(&bridge, presentation, prompts);
            var snapshot = bridge.snapshot().?;
            if (presentation == .protected_form or index != 0) try std.testing.expect(try prefill.suggest(&snapshot, id, original, true, at59) == null);
            for ([_]auth.Kind{ .password, .private_key_passphrase, .host_key_unknown, .host_key_changed }) |kind| {
                snapshot.kind = kind;
                try std.testing.expect(try prefill.suggest(&snapshot, id, original, true, at59) == null);
            }
        }
    }
}

test "TOTP autofill frozen create spec selects only original route hop seed" {
    var hop_seed = seed.*;
    const input: sessions.SessionCreateSpec = .{ .saved = .{ .connection_id = @fromBackingInt(42), .config_revision = 9, .protocol = .sftp, .immutable_config = .{ .endpoint = .{ .host = "target.example", .user = "root" }, .totp_secret = "MZXW6" }, .route_snapshot = &.{.{ .owner = original.owner(), .endpoint = .{ .host = original.host, .port = original.port, .user = original.user }, .totp_secret = &hop_seed }} } };
    var frozen = try @import("ui/session_lifecycle.zig").Snapshot(sessions.SessionCreateSpec).init(a, input);
    defer frozen.deinit();
    @memset(&hop_seed, 'A');
    var bridge: auth.InteractiveBridge = .{};
    const id = try otp(&bridge);
    var snapshot = bridge.snapshot().?;
    var value = (try prefill.suggestForSpec(&snapshot, id, frozen.value, true, at59)).?;
    defer value.deinit();
    try std.testing.expectEqualStrings("287082", value.code.slice());
    var wrong_hop = id;
    wrong_hop.hop_index = 1;
    try std.testing.expect(try prefill.suggestForSpec(&snapshot, wrong_hop, frozen.value, true, at59) == null);
    bridge.resetForAttempt();
    const final_id = try bridge.offerChallenge(.{ .key = key, .source_owner = .{ .id = @fromBackingInt(42), .revision = 9 }, .hop_index = 1, .kind = .keyboard_interactive, .endpoint_identity = .{ .host = "target.example", .user = "root" }, .prompts = &.{.{ .text = "OTP", .kind = .one_time_code }}, .presentation = .otp_modal, .presentation_config_revision = 8 });
    snapshot = bridge.snapshot().?;
    var final_value = (try prefill.suggestForSpec(&snapshot, final_id, frozen.value, true, at59)).?;
    defer final_value.deinit();
    try std.testing.expectEqualStrings("398408", final_value.code.slice());
    try std.testing.expect(try prefill.suggestForSpec(&snapshot, final_id, .{ .local = .{} }, true, at59) == null);
}

test "TOTP autofill validates injected clock window and original challenge deadline" {
    var bridge: auth.InteractiveBridge = .{};
    const id = try otp(&bridge);
    var snapshot = bridge.snapshot().?;
    snapshot.expires_at_ns = 20;
    var value = (try prefill.suggest(&snapshot, id, original, true, at59)).?;
    defer value.deinit();
    try std.testing.expect(value.validAt(at59));
    try std.testing.expect(!value.validAt(.{ .unix_seconds = 60, .monotonic_ns = 11 }));
    try std.testing.expect(!value.validAt(.{ .unix_seconds = 59, .monotonic_ns = 20 }));
    try std.testing.expect(try prefill.suggest(&snapshot, id, original, true, .{ .unix_seconds = 59, .monotonic_ns = 20 }) == null);
    snapshot.state = .expired;
    try std.testing.expect(try prefill.suggest(&snapshot, id, original, true, at59) == null);
    snapshot.state = .cancelled;
    try std.testing.expect(try prefill.suggest(&snapshot, id, original, true, at59) == null);
}

test "TOTP autofill real Input waits for explicit confirmation and old retry response stays invalid" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.show();
    try std.testing.expect(try f.fill(id));
    try std.testing.expectEqualStrings("287082", f.view.fields[0].input.state.getText());
    try std.testing.expectEqual(@as(usize, 0), f.submitted);
    try std.testing.expectEqual(auth.State.input, f.bridge.snapshot().?.state);
    try std.testing.expect(!f.view.submit_disabled.peek());
    f.cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(@as(usize, 1), f.submitted);
    var response = try f.bridge.waitResponse(id, 50);
    defer response.deinit();
    try std.testing.expectEqualStrings("287082", response.answerAt(0));
    try std.testing.expectEqualStrings("", f.view.fields[0].input.state.getText());
    const retry = try f.bridge.reject(id, error.AuthenticationDenied);
    try f.view.show(f.bridge.snapshot().?);
    try std.testing.expect(try f.fill(retry));
    var old = try proposal(&f.bridge, retry, at59);
    defer old.deinit();
    old.identity = id;
    try std.testing.expect(!try f.view.prefillOtp(old, f.clock()));
    try std.testing.expectError(error.StaleChallenge, f.bridge.submit(id, .{ .answers = &.{"287082"} }));
    try std.testing.expectEqual(auth.State.failed, f.bridge.snapshot().?.state);
    try std.testing.expectEqual(@as(usize, 1), f.submitted);
}

test "TOTP autofill updates untouched windows and never replaces manual edits" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.show();
    try std.testing.expect(try f.fill(id));
    const state = f.view.fields[0].input.state;
    try std.testing.expect(!try f.fill(id));
    f.time.unix_seconds = 60;
    try std.testing.expect(try f.fill(id));
    try std.testing.expectEqual(state, f.view.fields[0].input.state);
    try std.testing.expectEqualStrings("359152", state.getText());
    f.edit("123456");
    try std.testing.expect(f.view.otp_edited);
    f.time.unix_seconds = 90;
    try std.testing.expect(!try f.fill(id));
    try std.testing.expectEqualStrings("123456", state.getText());
    f.view.submit();
    var response = try f.bridge.waitResponse(id, 50);
    defer response.deinit();
    try std.testing.expectEqualStrings("123456", response.answerAt(0));
}

test "TOTP autofill stale automatic code never submits and hide expiry cancel erase Input" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.show();
    try std.testing.expect(try f.fill(id));
    f.time.unix_seconds = 60;
    f.view.submit();
    try std.testing.expectEqual(@as(usize, 0), f.submitted);
    try std.testing.expectEqualStrings("", f.view.fields[0].input.state.getText());
    try std.testing.expect(f.view.otp_prefill == null);
    try std.testing.expect(try f.fill(id));
    f.view.hide();
    try std.testing.expectEqualStrings("", f.view.fields[0].input.state.getText());
    try std.testing.expect(f.view.otp_prefill == null);
    try f.view.show(f.bridge.snapshot().?);
    try std.testing.expect(try f.fill(id));
    var expired = f.bridge.snapshot().?;
    expired.state = .expired;
    try f.view.show(expired);
    try std.testing.expectEqualStrings("", f.view.fields[0].input.state.getText());
    try std.testing.expect(f.view.otp_prefill == null);
    try std.testing.expect(!try f.fill(id));
    f.view.cancel();
    try std.testing.expectEqual(auth.State.cancelled, f.bridge.snapshot().?.state);
}

test "TOTP autofill adapter API declarations compile with original owner callbacks" {
    _ = &@import("ui/workspace.zig").Workspace.authenticationTotp;
    _ = &@import("ui/connection_host.zig").Host.mount;
    _ = &@import("ui/wizard_probe.zig").Controller.authenticationTotp;
    _ = &@import("ui/probe_connection_host.zig").Host.mount;
    _ = &@import("ui/file_application_host.zig").Host.bind;
    _ = &@import("ui/socks_application_host.zig").Host.bindAuthentication;
}

comptime {
    _ = @import("ssh_totp_tests.zig");
    _ = @import("file_authentication_tests.zig");
}
