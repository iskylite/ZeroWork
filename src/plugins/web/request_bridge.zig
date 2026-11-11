//! Main-thread transfer from WebKit's bounded callback queue to the owning
//! window's existing challenge host. Only public prompt data enters the host;
//! answers are taken once, passed to WebKit, and immediately cleared.
const std = @import("std");
const identity = @import("../../host/identity.zig");
const host_api = @import("../../host/challenge_host.zig");
const web = @import("../../host/web_surface.zig");
const auth = @import("../../proto/ssh/auth_challenge.zig");
const realtime = @import("../../platform/realtime.zig");

pub const Bridge = struct {
    owner: identity.SessionHandle,
    host: *host_api.Host,
    counter: *auth.RequestCounter,
    visible: ?Pending = null,

    const Pending = struct { token: u64, request_id: u64, kind: web.RequestKind };

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
                try submit(surface, pending, answer.value);
                changed = true;
            } else {
                const state = self.host.stateFor(self.owner, pending.request_id, self.owner.generation);
                if (state == .pending) return false;
                _ = self.retire();
                _ = try surface.replyRequest(pending.token, false, "", "");
                changed = true;
            }
        }
        var request = (try surface.copyRequest()) orelse return changed;
        defer request.deinit();
        const request_id = self.counter.next() catch |err| {
            _ = try surface.replyRequest(request.token, false, "", "");
            return err;
        };
        self.offer(request, request_id) catch |err| {
            // A full host mailbox is temporary; retain the bounded native
            // request until capacity returns or its native timeout expires.
            if (err == error.ChallengeQueueFull) return changed;
            _ = try surface.replyRequest(request.token, false, "", "");
            return err;
        };
        self.visible = .{ .token = request.token, .request_id = request_id, .kind = request.kind };
        return true;
    }

    fn retire(self: *Bridge) bool {
        const pending = self.visible orelse return false;
        self.visible = null;
        self.host.retire(self.owner, pending.request_id, self.owner.generation);
        return true;
    }

    fn offer(self: *Bridge, request: anytype, request_id: u64) !void {
        const now: u64 = @intCast(@max(0, realtime.monotonicNs()) / std.time.ns_per_ms);
        const title: []const u8 = switch (request.kind) {
            .alert => "网页提示",
            .confirm => "网页确认",
            .prompt => "网页输入",
            .http_auth => "网站登录",
            .notice => "暂不支持此操作",
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
