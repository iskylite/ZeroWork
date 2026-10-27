//! Main-thread adapter from the original SSH authentication mailbox into the
//! shared host challenge contract. Native authentication and trust persistence
//! keep their original request/operation identities and worker-owned bridges.
const std = @import("std");
const auth = @import("../../proto/ssh/auth_challenge.zig");
const shared = @import("../../host/challenge_host.zig");
const host_key = @import("../../ui/host_key_confirmation.zig");
pub const Details = struct { allow_save_password: bool = false, display_name: []const u8 = "", private_key_path: []const u8 = "", host_key: ?host_key.Request = null };
pub const Callbacks = struct {
    context: *anyopaque,
    submit: *const fn (*anyopaque, auth.RequestIdentity, auth.Reply) anyerror!void,
    save_password: ?*const fn (*anyopaque, auth.Snapshot, []const u8) anyerror!void = null,
    cancel: *const fn (*anyopaque, auth.RequestIdentity) void,
};
pub const Bridge = struct {
    current: ?auth.Snapshot = null,
    host: ?*shared.Host = null,
    forwarded: bool = false,
    password_save_failed: bool = false,
    pub fn owner(request: auth.RequestIdentity) shared.Owner {
        return .{ .operation = request.key };
    }
    pub fn generation(request: auth.RequestIdentity) u64 {
        return request.key.attempt_id orelse 1;
    }
    pub fn visible(self: *const Bridge) bool {
        return self.current != null and !self.forwarded;
    }
    pub fn clear(self: *Bridge) void {
        if (self.current) |request| if (self.host) |host| host.retire(owner(request.identity), request.identity.request_id, generation(request.identity));
        self.current = null;
        self.forwarded = false;
        self.password_save_failed = false;
    }
    pub fn sync(self: *Bridge, host: *shared.Host, incoming: ?auth.Snapshot, details: Details, callbacks: Callbacks, now_ms: u64) !void {
        self.host = host;
        if (self.current) |current| {
            const same = if (incoming) |request| current.identity.eql(request.identity) else false;
            if (!same) self.clear();
        }
        if (self.current) |current| {
            const id = current.identity;
            if (host.takeAnswer(owner(id), id.request_id, generation(id))) |incoming_answer| {
                var answer = incoming_answer;
                defer answer.deinit();
                const reply: auth.Reply = switch (current.kind) {
                    .host_key_unknown => if (answer.value == .choice and std.mem.eql(u8, answer.value.choice, "trust_once")) .trust_once else if (answer.value == .choice and std.mem.eql(u8, answer.value.choice, "trust_save")) .trust_save else return error.InvalidChallengeResponse,
                    .host_key_changed => if (answer.value == .fields and answer.value.fields.len == 1) .{ .replace_host_key = answer.value.fields[0] } else return error.InvalidChallengeResponse,
                    else => if (answer.value == .fields) .{ .answers = answer.value.fields } else return error.InvalidChallengeResponse,
                };
                if (answer.save_password and current.kind == .password and answer.value == .fields and answer.value.fields.len == 1) {
                    const save = callbacks.save_password orelse return error.PasswordPersistenceUnavailable;
                    save(callbacks.context, current, answer.value.fields[0]) catch |err| {
                        self.clear();
                        self.password_save_failed = true;
                        return err;
                    };
                    self.password_save_failed = false;
                }
                try callbacks.submit(callbacks.context, id, reply);
                self.forwarded = true;
                return;
            }
            const state = host.stateFor(owner(id), id.request_id, generation(id));
            if (state == .withdrawn or state == .timed_out or state == .cancelled) {
                callbacks.cancel(callbacks.context, id);
                self.clear();
                return;
            }
            if (incoming) |request| if (request.state == .submitting or request.state == .completed or request.state == .cancelled or request.state == .expired) {
                self.clear();
                return;
            };
            return;
        }
        const request = incoming orelse return;
        if (request.state != .input and request.state != .failed) return;
        if (request.expires_at_ns) |expiry| if (expiry <= @as(i128, now_ms) * std.time.ns_per_ms) {
            callbacks.cancel(callbacks.context, request.identity);
            return;
        };
        if ((request.kind == .host_key_unknown or request.kind == .host_key_changed) and details.host_key == null) return error.TrustMaterialUnavailable;
        var arena = std.heap.ArenaAllocator.init(host.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const endpoint = request.endpoint();
        const source = try std.fmt.allocPrint(allocator, "{s} · {s}@{s}:{d} · 第 {d} 跳", .{ if (details.display_name.len == 0) endpoint.host else details.display_name, endpoint.user, endpoint.host, endpoint.port, request.identity.hop_index + 1 });
        var payload: shared.Payload = .{ .allow_save_password = details.allow_save_password and request.kind == .password, .title = title(request.kind), .source_name = source, .detail = if (request.state == .failed) "认证未通过，请核对后重新填写；取消会停止本次连接。" else if (details.allow_save_password and request.kind == .password) "可选择保存密码供下次连接使用；取消会停止本次认证。" else "仅用于当前连接；取消会停止本次认证。", .submit_label = submitLabel(request.kind) };
        if (self.password_save_failed and request.kind == .password) payload.detail = "密码保存失败。请解锁或授权系统钥匙串后重试，也可取消勾选保存密码后仅连接本次。";
        var fields: [auth.max_prompts]shared.Field = undefined;
        const kind: shared.Kind = switch (request.kind) {
            .host_key_unknown, .host_key_changed => .trust_material,
            else => .secret_input,
        };
        if (details.host_key) |key| {
            payload.material = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}{s}{s}\n记录路径：{s}", .{ key.algorithmSlice(), key.fingerprintSlice(), if (request.kind == .host_key_changed) "原密钥：" else "", key.old_algorithm[0..key.old_algorithm_len], key.old_fingerprint[0..key.old_fingerprint_len], key.store_path[0..key.store_path_len] });
        }
        switch (request.kind) {
            .host_key_unknown => {
                payload.detail = "请通过可信渠道核对指纹。仅本次信任不写记录；保存并继续会记录本次核对的密钥。";
                payload.choices = &.{ .{ .value = "trust_once", .label = "仅本次信任" }, .{ .value = "trust_save", .label = "保存并继续" } };
            },
            .host_key_changed => {
                payload.detail = "服务器密钥与已保存记录不同。请先通过可信渠道核对新指纹，取消将保留原记录。";
                fields[0] = .{ .label = "输入小写 yes，确认替换已保存的密钥", .secret = false, .max_bytes = 3, .confirmation = "yes" };
                payload.fields = fields[0..1];
            },
            else => {
                if (request.prompt_count == 0) return error.InvalidChallengePrompt;
                for (0..request.prompt_count) |i| {
                    const prompt = request.promptAt(i);
                    fields[i] = .{ .label = prompt.text, .secret = !prompt.echo, .max_bytes = auth.InteractiveBridge.max_answer };
                }
                payload.fields = fields[0..request.prompt_count];
                if (request.kind == .private_key_passphrase) payload.detail = try std.fmt.allocPrint(allocator, "私钥：{s}\n密码短语仅用于本次解锁。", .{details.private_key_path});
            },
        }
        const deadline: u64 = if (request.expires_at_ns) |expiry| @intCast(@max(1, @divTrunc(expiry, std.time.ns_per_ms))) else std.math.maxInt(u64);
        try host.offer(owner(request.identity), request.identity.request_id, generation(request.identity), kind, payload, deadline);
        self.current = request;
        self.forwarded = false;
    }
};
fn title(kind: auth.Kind) []const u8 {
    return switch (kind) {
        .password => "SSH 密码认证",
        .private_key_passphrase => "解锁 SSH 私钥",
        .keyboard_interactive => "SSH 追加认证",
        .host_key_unknown => "核对主机密钥",
        .host_key_changed => "主机密钥已变更",
    };
}
fn submitLabel(kind: auth.Kind) []const u8 {
    return switch (kind) {
        .password => "认证并继续",
        .private_key_passphrase => "解锁并继续",
        .keyboard_interactive => "验证并继续",
        .host_key_unknown => "保存并继续",
        .host_key_changed => "替换密钥并继续",
    };
}
