//! Main-thread transfer from WebKit's bounded callback queue to the owning
//! window's existing challenge host. Only public prompt data enters the host;
//! answers are taken once, passed to WebKit, and immediately cleared.
const std = @import("std");
const identity = @import("../../host/identity.zig");
const host_api = @import("../../host/challenge_host.zig");
const web = @import("../../host/web_surface.zig");
const auth = @import("../../proto/ssh/auth_challenge.zig");
const tls = @import("../../host/tls_trust.zig");
const realtime = @import("../../platform/realtime.zig");

pub const Bridge = struct {
    owner: identity.SessionHandle,
    host: *host_api.Host,
    counter: *auth.RequestCounter,
    visible: ?Pending = null,
    tls_context: ?struct { trust: tls.Facade, operation: tls.OperationKey } = null,
    tls_error: ?[]const u8 = null,

    const Pending = struct { token: u64, request_id: u64, kind: web.RequestKind, tls_challenge: ?tls.Challenge = null };

    pub fn init(owner: identity.SessionHandle, host: *host_api.Host, counter: *auth.RequestCounter) Bridge {
        return .{ .owner = owner, .host = host, .counter = counter };
    }

    pub fn cancel(self: *Bridge, surface: anytype) void {
        _ = self.retire();
        surface.cancelRequests() catch {};
    }

    pub fn poll(self: *Bridge, surface: anytype) !bool {
        var changed = false;
        if (self.visible) |pending| {
            // Native navigation/stop/timeout may have retired the callback
            // while a submitted answer was waiting in the host mailbox.
            if (!try surface.requestPending(pending.token)) {
                changed = self.retire();
            } else if (self.host.takeAnswer(self.owner, pending.request_id, self.owner.generation)) |incoming| {
                var answer = incoming;
                defer answer.deinit();
                self.visible = null;
                errdefer _ = surface.replyRequest(pending.token, false, "", "") catch false;
                if (pending.tls_challenge) |challenge| {
                    self.finishTls(surface, pending.token, challenge, answer.value);
                } else try submit(surface, pending, answer.value);
                changed = true;
            } else {
                const state = self.host.stateFor(self.owner, pending.request_id, self.owner.generation);
                if (state == .pending) return false;
                if (pending.tls_challenge != null) self.tls_error = "未信任网站证书。";
                _ = self.retire();
                _ = try surface.replyRequest(pending.token, false, "", "");
                changed = true;
            }
        }
        var request = (try surface.copyRequest()) orelse return changed;
        defer request.deinit();
        var tls_challenge: ?tls.Challenge = null;
        if (request.kind == .server_trust) {
            const context = self.tls_context orelse {
                _ = try surface.replyRequest(request.token, true, "system", "");
                return true;
            };
            self.tls_error = null;
            const evaluation = surface.evaluateTlsPeer(request.token, context.trust, context.operation) catch {
                self.tls_error = "无法检查网站证书。";
                _ = try surface.replyRequest(request.token, false, "", "");
                return true;
            };
            switch (evaluation) {
                .trusted => |decision| {
                    _ = try surface.replyRequest(request.token, true, if (decision.source == .system or decision.verification.failures.empty()) "system" else "exception", "");
                    return true;
                },
                .denied => {
                    self.tls_error = "网站证书无法通过校验，不能继续访问。";
                    _ = try surface.replyRequest(request.token, false, "", "");
                    return true;
                },
                .challenge => |challenge| tls_challenge = challenge,
            }
        }
        const request_id = self.counter.next() catch |err| {
            self.rejectTls(tls_challenge);
            _ = try surface.replyRequest(request.token, false, "", "");
            return err;
        };
        self.offer(request, request_id, tls_challenge) catch |err| {
            // A full host mailbox is temporary; retain the bounded native
            // request until capacity returns or its native timeout expires.
            self.rejectTls(tls_challenge);
            if (err == error.ChallengeQueueFull) return changed;
            _ = try surface.replyRequest(request.token, false, "", "");
            return err;
        };
        self.visible = .{ .token = request.token, .request_id = request_id, .kind = request.kind, .tls_challenge = tls_challenge };
        return true;
    }

    fn retire(self: *Bridge) bool {
        const pending = self.visible orelse return false;
        self.visible = null;
        self.host.retire(self.owner, pending.request_id, self.owner.generation);
        self.rejectTls(pending.tls_challenge);
        return true;
    }

    fn rejectTls(self: *Bridge, pending: ?tls.Challenge) void {
        const challenge = pending orelse return;
        const context = self.tls_context orelse return;
        _ = context.trust.answer(challenge, .reject) catch {};
    }

    fn finishTls(self: *Bridge, surface: anytype, token: u64, challenge: tls.Challenge, value: host_api.Reply) void {
        const context = self.tls_context.?;
        const choice: tls.TrustChoice = if (value == .choice and std.mem.eql(u8, value.choice, "persistent")) .persistent else if (value == .choice and std.mem.eql(u8, value.choice, "once")) .once else .reject;
        const evaluation = context.trust.answer(challenge, choice) catch {
            self.rejectTls(challenge);
            self.tls_error = "无法保存或应用证书信任，请重新加载后重试。";
            _ = surface.replyRequest(token, false, "", "") catch false;
            return;
        };
        if (evaluation == .trusted) {
            _ = surface.replyRequest(token, true, if (evaluation.trusted.verification.failures.empty()) "system" else "exception", "") catch false;
        } else {
            self.tls_error = "未信任网站证书。";
            _ = surface.replyRequest(token, false, "", "") catch false;
        }
    }

    fn offer(self: *Bridge, request: anytype, request_id: u64, tls_challenge: ?tls.Challenge) !void {
        const now: u64 = @intCast(@max(0, realtime.monotonicNs()) / std.time.ns_per_ms);
        if (tls_challenge) |challenge| {
            const verification = &challenge.verification;
            const allocator = self.host.allocator;
            const starts = try tls.utcDate(allocator, verification.not_before_unix);
            defer allocator.free(starts);
            const ends = try tls.utcDate(allocator, verification.not_after_unix);
            defer allocator.free(ends);
            const failures = try tls.describeFailures(allocator, verification.failures);
            defer allocator.free(failures);
            try self.host.offer(self.owner, request_id, self.owner.generation, .choice, .{
                .title = if (challenge.scope_changed) "网站证书已变化" else "无法验证网站身份",
                .detail = "请核对证书指纹。继续访问可能将登录信息交给冒充该网站的服务器。",
                .source_name = "HTTPS",
                .certificate_trust = .{
                    .authority = std.mem.span(request.origin),
                    .leaf_fingerprint = verification.leaf_fingerprint,
                    .chain_fingerprint = verification.chain_fingerprint,
                    .subject = verification.subjectText(),
                    .issuer = verification.issuerText(),
                    .valid_from = starts,
                    .valid_until = ends,
                    .failures = failures,
                    .scope_changed = challenge.scope_changed,
                },
                .choices = &.{
                    .{ .value = "reject", .label = "拒绝连接" },
                    .{ .value = "once", .label = "仅本次信任" },
                    .{ .value = "persistent", .label = "保存并继续" },
                },
            }, now + 120_000);
            return;
        }
        const title: []const u8 = switch (request.kind) {
            .alert => "网页提示",
            .confirm => "网页确认",
            .prompt => "网页输入",
            .http_auth => "网站登录",
            .notice => "暂不支持此操作",
            .server_trust => return error.InvalidWebPageReply,
        };
        const fields: []const host_api.Field = switch (request.kind) {
            .prompt => &.{.{ .label = "输入内容", .secret = false, .allow_empty = true, .initial_value = std.mem.span(request.default_text) }},
            .http_auth => &.{
                .{ .label = "用户名", .secret = false, .allow_empty = true },
                .{ .label = "密码", .secret = true, .allow_empty = true },
            },
            else => &.{},
        };
        const message = std.mem.span(request.message);
        const realm = std.mem.span(request.realm);
        const long_message = message.len > 320 or std.mem.count(u8, message, "\n") > 2;
        var material_buffer: [12289]u8 = undefined;
        const material = if (long_message and realm.len != 0)
            try std.fmt.bufPrint(&material_buffer, "{s}\n{s}", .{ message, realm })
        else if (long_message)
            message
        else
            realm;
        try self.host.offer(self.owner, request_id, self.owner.generation, if (fields.len == 0) .choice else .secret_input, .{
            .title = title,
            .detail = if (long_message) "" else message,
            .source_name = std.mem.span(request.origin),
            .material = material,
            .fields = fields,
            .choices = if (fields.len == 0) &.{.{ .value = "accept", .label = "确定" }} else &.{},
        }, now + 120_000);
    }

    fn submit(surface: anytype, pending: Pending, value: host_api.Reply) !void {
        switch (pending.kind) {
            .alert, .confirm, .notice => {
                if (value != .choice or !std.mem.eql(u8, value.choice, "accept")) return error.InvalidWebPageReply;
                _ = try surface.replyRequest(pending.token, true, "", "");
            },
            .prompt => {
                if (value != .fields or value.fields.len != 1) return error.InvalidWebPageReply;
                _ = try surface.replyRequest(pending.token, true, value.fields[0], "");
            },
            .server_trust => return error.InvalidWebPageReply,
            .http_auth => {
                if (value != .fields or value.fields.len != 2) return error.InvalidWebPageReply;
                _ = try surface.replyRequest(pending.token, true, value.fields[0], value.fields[1]);
            },
        }
    }
};

test "web page prompt keeps origin and default, accepts empty once, and rejects a stale answer" {
    const Fake = struct {
        const Request = struct {
            token: u64 = 91,
            kind: web.RequestKind = .prompt,
            origin: [*:0]const u8 = "https://iframe.example:8443",
            message: [*:0]const u8 = "输入名称",
            default_text: [*:0]const u8 = "默认值",
            realm: [*:0]const u8 = "",
            fn deinit(_: *@This()) void {}
        };
        pending: bool = true,
        replies: usize = 0,
        accepted: bool = false,
        value_len: usize = 99,
        fn evaluateTlsPeer(_: *@This(), _: u64, _: tls.Facade, _: tls.OperationKey) !tls.Evaluation {
            return error.UnexpectedTlsRequest;
        }
        fn requestPending(self: *@This(), token: u64) !bool {
            return self.pending and token == 91;
        }
        fn copyRequest(self: *@This()) !?Request {
            return if (self.pending) .{} else null;
        }
        fn replyRequest(self: *@This(), token: u64, accepted: bool, value: []const u8, _: []const u8) !bool {
            if (!try self.requestPending(token)) return false;
            self.pending = false;
            self.replies += 1;
            self.accepted = accepted;
            self.value_len = value.len;
            return true;
        }
        fn cancelRequests(self: *@This()) !void {
            _ = try self.replyRequest(91, false, "", "");
        }
    };
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(1) };
    var host = host_api.Host.init(std.testing.allocator);
    defer host.deinit();
    var ids: auth.RequestCounter = .{};
    // SSH and page prompts consume the same identity sequence.
    try std.testing.expectEqual(@as(u64, 1), try ids.next());
    var bridge = Bridge.init(owner, &host, &ids);
    var surface: Fake = .{};
    try std.testing.expect(try bridge.poll(&surface));
    const prompt = host.snapshot(0, owner).?;
    try std.testing.expectEqual(@as(u64, 2), prompt.request_id);
    try std.testing.expectEqualStrings("https://iframe.example:8443", prompt.payload.source_name);
    try std.testing.expectEqualStrings("默认值", prompt.payload.fields[0].initial_value);
    try std.testing.expect(!prompt.payload.fields[0].secret and prompt.payload.fields[0].allow_empty);
    const now: u64 = @intCast(@max(0, realtime.monotonicNs()) / std.time.ns_per_ms);
    try host.submitAnswer(owner, prompt.request_id, owner.generation, .{ .fields = &.{""} }, now);
    try std.testing.expect(try bridge.poll(&surface));
    try std.testing.expect(surface.accepted and surface.value_len == 0 and surface.replies == 1);
    try std.testing.expect(!try bridge.poll(&surface));
    try std.testing.expectError(error.ChallengeMismatch, host.submitAnswer(owner, prompt.request_id, owner.generation, .{ .fields = &.{"late"} }, now));

    surface.pending = true;
    try std.testing.expect(try bridge.poll(&surface));
    const stale_id = bridge.visible.?.request_id;
    try host.submitAnswer(owner, stale_id, owner.generation, .{ .fields = &.{"late"} }, now);
    // Simulates WebKit cancelling on navigation before runtime's next poll.
    surface.pending = false;
    try std.testing.expect(try bridge.poll(&surface));
    try std.testing.expectEqual(@as(usize, 1), surface.replies);
    try std.testing.expect(host.takeAnswer(owner, stale_id, owner.generation) == null);
    try std.testing.expect(host.stateFor(owner, stale_id, owner.generation) == null);
}
