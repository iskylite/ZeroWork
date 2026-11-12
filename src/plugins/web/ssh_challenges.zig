//! Presents existing SSH worker challenges through the owning window's
//! plugin challenge host. Credentials stay in the original SSH bridges.
const std = @import("std");
const identity = @import("../../host/identity.zig");
const OperationKey = @import("../../host/operation.zig").OperationKey;
const host_api = @import("../../host/challenge_host.zig");
const transport = @import("../../host/transport_factory.zig");
const ssh = @import("../../proto/ssh/session.zig");
const auth = @import("../../proto/ssh/auth_challenge.zig");
const host_key = @import("../../ui/host_key_confirmation.zig");
const realtime = @import("../../platform/realtime.zig");

pub const Bridge = struct {
    owner: identity.SessionHandle,
    operation: OperationKey,
    host: *host_api.Host,
    credentials: ?transport.Credentials = null,
    authentication: auth.InteractiveBridge,
    trust: host_key.Bridge,
    visible_request: ?auth.RequestIdentity = null,

    pub fn init(owner: identity.SessionHandle, operation: OperationKey, host: *host_api.Host, counter: *auth.RequestCounter) Bridge {
        return .{
            .owner = owner,
            .operation = operation,
            .host = host,
            .authentication = .{ .request_counter = counter },
            .trust = .{ .request_counter = counter },
        };
    }

    pub fn configure(self: *Bridge, factory: *transport.Factory) void {
        if (factory.credentials != null) {
            self.credentials = factory.credentials;
            factory.credentials = .{ .context = self, .resolve = resolveCredentials };
        }
        factory.auth_interaction = .{ .bridge = &self.authentication };
        factory.host_key_observer = .{ .ctx = &self.trust, .callback = host_key.Bridge.observer };
    }

    pub fn cancel(self: *Bridge) void {
        self.authentication.cancel();
        self.trust.cancel();
        _ = self.retire();
    }

    pub fn poll(self: *Bridge) !bool {
        const pending: Pending = if (self.trust.snapshot()) |request|
            .{ .key = request }
        else if (self.authentication.snapshot()) |request| switch (request.state) {
            .input, .failed => .{ .credentials = request },
            else => return self.retire(),
        } else return self.retire();
        const request = pending.identity() orelse return error.InvalidWebSshChallenge;
        if (!request.key.eql(self.operation)) return error.InvalidWebSshChallenge;
        if (self.visible_request == null or !self.visible_request.?.eql(request)) {
            _ = self.retire();
            try self.offer(pending, request.request_id);
            self.visible_request = request;
            return true;
        }
        if (self.host.takeAnswer(self.owner, request.request_id, self.owner.generation)) |reply| {
            var answer = reply;
            defer answer.deinit();
            self.visible_request = null;
            try self.submit(pending, request, answer.value);
            return true;
        }
        const state = self.host.stateFor(self.owner, request.request_id, self.owner.generation);
        if (state == null or state == .withdrawn or state == .timed_out or state == .cancelled) return error.Cancelled;
        return false;
    }

    fn retire(self: *Bridge) bool {
        const request = self.visible_request orelse return false;
        self.visible_request = null;
        self.host.retire(self.owner, request.request_id, self.owner.generation);
        return true;
    }

    fn offer(self: *Bridge, pending: Pending, request_id: u64) !void {
        const now: u64 = @intCast(@max(0, realtime.monotonicNs()) / std.time.ns_per_ms);
        switch (pending) {
            .credentials => |request| {
                const endpoint = request.endpoint();
                var detail: [1600]u8 = undefined;
                const target = try std.fmt.bufPrint(&detail, "跳板 {d} · {s}@{s}:{d}", .{ request.identity.hop_index + 1, endpoint.user, endpoint.host, endpoint.port });
                var fields: [auth.max_prompts]host_api.Field = undefined;
                for (fields[0..request.prompt_count], 0..) |*field, index| {
                    const prompt = request.promptAt(index);
                    field.* = .{
                        .label = if (prompt.text.len == 0) "输入凭据" else prompt.text,
                        .secret = !prompt.echo,
                        .max_bytes = auth.InteractiveBridge.max_answer,
                    };
                }
                try self.host.offer(self.owner, request_id, self.owner.generation, .secret_input, .{
                    .title = switch (request.kind) {
                        .password => "SSH 密码",
                        .private_key_passphrase => "解锁 SSH 私钥",
                        else => "SSH 交互认证",
                    },
                    .detail = target,
                    .source_name = "浏览器连接",
                    .fields = fields[0..request.prompt_count],
                }, now + 60_000);
            },
            .key => |request| {
                var material: [1800]u8 = undefined;
                const changed = request.status == .changed;
                const lines = if (changed)
                    try std.fmt.bufPrint(&material, "{s}:{d}\n原指纹  {s}\n新指纹  {s}  {s}", .{
                        request.hostSlice(), request.port, request.old_fingerprint[0..request.old_fingerprint_len], request.algorithmSlice(), request.fingerprintSlice(),
                    })
                else
                    try std.fmt.bufPrint(&material, "{s}:{d}\n{s}  {s}", .{
                        request.hostSlice(), request.port, request.algorithmSlice(), request.fingerprintSlice(),
                    });
                const choices = [_]host_api.Option{
                    .{ .value = "trust_once", .label = "仅本次信任" },
                    .{ .value = "trust_save", .label = "保存并继续" },
                };
                try self.host.offer(self.owner, request_id, self.owner.generation, .trust_material, .{
                    .title = if (changed) "主机密钥已变更" else "确认 SSH 主机密钥",
                    .detail = if (changed) "核对新指纹后，输入 yes 替换保存的主机密钥。" else "通过可信渠道核对跳板指纹。",
                    .source_name = "浏览器连接",
                    .material = lines,
                    .fields = if (changed) &.{.{ .label = "输入 yes", .secret = false, .max_bytes = 3, .confirmation = "yes" }} else &.{},
                    .choices = if (changed) &.{} else choices[0..if (request.store_path_len == 0) @as(usize, 1) else 2],
                    .submit_label = if (changed) "替换密钥并连接" else "确认",
                }, now + 300_000);
            },
        }
    }

    fn submit(self: *Bridge, pending: Pending, request: auth.RequestIdentity, reply: host_api.Reply) !void {
        switch (pending) {
            .credentials => {
                if (reply != .fields) return error.InvalidWebSshChallenge;
                try self.authentication.submit(request, .{ .answers = reply.fields });
            },
            .key => {
                const decision: auth.Reply = switch (reply) {
                    .choice => |choice| if (std.mem.eql(u8, choice, "trust_once")) .trust_once else if (std.mem.eql(u8, choice, "trust_save")) .trust_save else return error.InvalidWebSshChallenge,
                    .fields => |fields| if (fields.len == 1) .{ .replace_host_key = fields[0] } else return error.InvalidWebSshChallenge,
                    else => return error.InvalidWebSshChallenge,
                };
                if (!self.trust.decideScoped(request, decision)) return error.InvalidWebSshChallenge;
            },
        }
    }

    fn resolveCredentials(raw: *anyopaque, owner: identity.ResourceOwner, source: identity.AssetOwner, a: std.mem.Allocator) !ssh.Auth {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        if (owner != .session or !owner.session.eql(self.owner)) return error.CredentialOwnerDenied;
        const credentials = self.credentials orelse return error.CredentialOwnerDenied;
        return credentials.resolve(credentials.context, owner, source, a) catch |err| switch (err) {
            error.AuthenticationInteractionRequired => .password_prompt,
            else => return err,
        };
    }
};

const Pending = union(enum) {
    credentials: auth.Snapshot,
    key: host_key.Request,

    fn identity(self: Pending) ?auth.RequestIdentity {
        return switch (self) {
            .credentials => |request| request.identity,
            .key => |request| .{
                .key = request.operation_key orelse return null,
                .hop_index = request.hop_index,
                .request_id = request.generation,
            },
        };
    }
};

test "web SSH challenge submits one reply to the exact worker request" {
    const testing = std.testing;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(1) };
    const operation: OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 42, .attempt_id = 1 };
    var host = host_api.Host.init(testing.allocator);
    defer host.deinit();
    var counter: auth.RequestCounter = .{};
    var bridge = Bridge.init(owner, operation, &host, &counter);
    defer bridge.cancel();

    const request = try bridge.authentication.offerChallenge(.{
        .key = operation,
        .hop_index = 0,
        .kind = .password,
        .endpoint_identity = .{ .host = "ssh.invalid", .user = "operator" },
        .prompts = &.{.{ .text = "Password" }},
        .presentation_config_revision = 1,
    });
    try testing.expect(try bridge.poll());
    const now: u64 = @intCast(@max(0, realtime.monotonicNs()) / std.time.ns_per_ms);
    const foreign: identity.SessionHandle = .{ .session_id = @fromBackingInt(2) };
    try testing.expectError(error.ChallengeMismatch, host.submitAnswer(foreign, request.request_id, owner.generation, .{ .fields = &.{"fixture-password"} }, now));
    try host.submitAnswer(owner, request.request_id, owner.generation, .{ .fields = &.{"fixture-password"} }, now);
    try testing.expect(try bridge.poll());
    var reply = try bridge.authentication.waitResponse(request, 0);
    defer reply.deinit();
    try testing.expectEqualStrings("fixture-password", reply.answerAt(0));
    try testing.expectError(error.ResponseConsumed, bridge.authentication.waitResponse(request, 0));
    try testing.expect(!try bridge.poll());
}
