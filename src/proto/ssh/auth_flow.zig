//! One synchronous worker's authentication conversation for one frozen hop.
//! The transport supplies exact server outcomes; AuthMachine owns method state.
const std = @import("std");
const challenge = @import("auth_challenge.zig");
const policy = @import("connection_policy.zig");
const identity = @import("../../host/identity.zig");
const OperationKey = @import("../../host/operation.zig").OperationKey;

pub const PrivateKeyAuth = struct { path: [:0]const u8, passphrase: ?[:0]const u8 = null };
pub const Auth = union(enum) { password: [:0]const u8, password_prompt, private_key: PrivateKeyAuth, agent, keyboard_interactive };
pub const KeyboardPrompt = struct {
    ctx: *anyopaque,
    callback: *const fn (*anyopaque, []const u8, []u8) ?[]const u8,
};
pub const Interaction = struct {
    bridge: *challenge.InteractiveBridge,
    presentation: challenge.Presentation = .protected_form,
    presentation_config_revision: u64 = 1,
    timeout_ms: u32 = 60_000,
};
pub const Methods = std.EnumSet(policy.AuthMethod);
pub const Advertised = struct { authenticated: bool = false, methods: Methods };
pub const Attempt = struct {
    outcome: policy.AuthMachine.Outcome,
    /// null means a local error, not a server failure or acceptance.
    remaining: ?Methods = null,
    key_unlock_failed: bool = false,
};
pub const Result = struct { accepted_methods: Methods };
pub const Config = struct {
    endpoint: challenge.EndpointIdentity,
    auth: Auth,
    source_owner: ?identity.AssetOwner = null,
    operation_key: ?OperationKey = null,
    hop_index: usize = 0,
    interaction: ?Interaction = null,
    legacy_keyboard: ?KeyboardPrompt = null,
    cancel_token: ?*const std.atomic.Value(bool) = null,
};

pub fn parseMethods(value: []const u8) !Methods {
    if (value.len > 1023 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidAuthenticationMethods;
    var methods: Methods = .init(.{});
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        if (part.len == 0) {
            if (value.len == 0) return methods;
            return error.InvalidAuthenticationMethods;
        }
        if (std.mem.eql(u8, part, "publickey")) {
            methods.insert(.agent);
            methods.insert(.private_key);
        } else if (std.mem.eql(u8, part, "password")) {
            methods.insert(.password);
        } else if (std.mem.eql(u8, part, "keyboard-interactive")) {
            methods.insert(.keyboard_interactive);
        }
    }
    return methods;
}

/// The native keyboard-interactive callback uses this same scoped conversation.
/// A subsequent server round completes the consumed round before publishing
/// new prompts; it does not mark an authentication method accepted.
pub const Conversation = struct {
    config: Config,
    last: ?challenge.RequestIdentity = null,
    retry_pending: bool = false,

    pub fn checkCancelled(self: *const Conversation) !void {
        if (self.config.cancel_token) |token| if (token.load(.acquire)) return error.Cancelled;
    }

    pub fn request(self: *Conversation, kind: challenge.Kind, prompts: []const challenge.Prompt) !challenge.Response {
        try self.checkCancelled();
        const interaction = self.config.interaction orelse return error.AuthenticationInteractionRequired;
        const key = self.config.operation_key orelse return error.AuthenticationScopeRequired;
        var replacing_retry: ?challenge.RequestIdentity = null;
        if (self.last) |previous| {
            const snapshot = interaction.bridge.snapshot() orelse return error.StaleChallenge;
            if (!snapshot.identity.eql(previous)) return error.StaleChallenge;
            if (self.retry_pending) {
                if (samePrompts(&snapshot, kind, prompts)) {
                    self.retry_pending = false;
                    return interaction.bridge.waitResponseCancellable(previous, interaction.timeout_ms, self.config.cancel_token);
                }
                replacing_retry = previous;
            } else if (snapshot.state == .submitting) {
                try interaction.bridge.complete(previous);
            }
        }
        const next: challenge.AuthChallenge = .{
            .key = key,
            .source_owner = self.config.source_owner,
            .hop_index = self.config.hop_index,
            .kind = kind,
            .endpoint_identity = self.config.endpoint,
            .prompts = prompts,
            .presentation = if (kind == .keyboard_interactive) interaction.presentation else .protected_form,
            .presentation_config_revision = interaction.presentation_config_revision,
        };
        const request_id = interaction.bridge.offerChallenge(next) catch |err| blk: {
            if (err != error.ChallengeBusy or replacing_retry == null) return err;
            // The UI may have submitted the old failed prompt while the
            // server was preparing a different next prompt group. Consume
            // and wipe that obsolete reply; never apply it to the new group.
            var obsolete = try interaction.bridge.waitResponseCancellable(replacing_retry.?, 0, self.config.cancel_token);
            obsolete.deinit();
            try interaction.bridge.complete(replacing_retry.?);
            break :blk try interaction.bridge.offerChallenge(next);
        };
        self.retry_pending = false;
        self.last = request_id;
        return interaction.bridge.waitResponseCancellable(request_id, interaction.timeout_ms, self.config.cancel_token);
    }

    fn complete(self: *Conversation) !void {
        if (self.last) |request_id| {
            const bridge = self.config.interaction.?.bridge;
            const snapshot = bridge.snapshot() orelse return error.StaleChallenge;
            if (snapshot.state == .submitting) try bridge.complete(request_id);
            self.last = null;
            self.retry_pending = false;
        }
    }

    fn reject(self: *Conversation) !bool {
        const request_id = self.last orelse return false;
        const bridge = self.config.interaction.?.bridge;
        const snapshot = bridge.snapshot() orelse return error.StaleChallenge;
        if (snapshot.state != .submitting) return false;
        self.last = try bridge.reject(request_id, error.AuthenticationFailed);
        self.retry_pending = true;
        return true;
    }
};

fn samePrompts(snapshot: *const challenge.Snapshot, kind: challenge.Kind, prompts: []const challenge.Prompt) bool {
    if (snapshot.kind != kind or snapshot.prompt_count != prompts.len) return false;
    for (prompts, 0..) |prompt, index| {
        const old = snapshot.promptAt(index);
        if (old.echo != prompt.echo or old.kind != prompt.kind or !std.mem.eql(u8, old.text, prompt.text)) return false;
    }
    return true;
}

const Secret = struct {
    bytes: [challenge.InteractiveBridge.max_answer + 1:0]u8 = @splat(0),
    len: usize = 0,
    fn take(self: *Secret, response: *const challenge.Response) void {
        const answer = response.answerAt(0);
        @memcpy(self.bytes[0..answer.len], answer);
        self.bytes[answer.len] = 0;
        self.len = answer.len;
    }
    fn value(self: *const Secret) [:0]const u8 {
        return self.bytes[0..self.len :0];
    }
    fn deinit(self: *Secret) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.len = 0;
    }
};

/// Backend.query() returns the initial advertised methods; Backend.attempt()
/// executes one method and returns the actual wire PARTIAL/SUCCESS outcome.
/// No retry reuses a rejected secret: each retry below waits for explicit input.
pub fn authenticate(config: Config, backend: anytype) !Result {
    errdefer if (config.interaction) |interaction| interaction.bridge.cancel();
    var conversation: Conversation = .{ .config = config };
    try conversation.checkCancelled();
    const advertised: Advertised = try backend.query();
    try conversation.checkCancelled();
    if (advertised.authenticated) return .{ .accepted_methods = .init(.{}) };
    var candidates: [3]policy.AuthMethod = undefined;
    var count: usize = 0;
    const first: policy.AuthMethod = switch (config.auth) {
        .agent => .agent,
        .private_key => .private_key,
        .password, .password_prompt => .password,
        .keyboard_interactive => .keyboard_interactive,
    };
    candidates[count] = first;
    count += 1;
    if (first != .password and first != .keyboard_interactive and config.interaction != null) {
        candidates[count] = .password;
        count += 1;
    }
    if (first != .keyboard_interactive and (config.interaction != null or config.legacy_keyboard != null)) {
        candidates[count] = .keyboard_interactive;
        count += 1;
    }
    var machine: policy.AuthMachine = .{ .methods = candidates[0..count], .remaining = advertised.methods };
    while (machine.next()) |method| {
        var prompt_password = method == .password and config.auth != .password;
        var prompt_passphrase = false;
        while (true) {
            try conversation.checkCancelled();
            var secret: Secret = .{};
            defer secret.deinit();
            var auth: Auth = switch (method) {
                .agent => .agent,
                .private_key => config.auth,
                .password => if (config.auth == .password) config.auth else .password_prompt,
                .keyboard_interactive => .keyboard_interactive,
            };
            if (prompt_password) {
                var response = try conversation.request(.password, &.{.{ .text = "Password:", .echo = false }});
                defer response.deinit();
                secret.take(&response);
                auth = .{ .password = secret.value() };
            } else if (prompt_passphrase) {
                var response = try conversation.request(.private_key_passphrase, &.{.{ .text = config.auth.private_key.path, .echo = false }});
                defer response.deinit();
                secret.take(&response);
                auth = .{ .private_key = .{ .path = config.auth.private_key.path, .passphrase = secret.value() } };
            }
            const attempt: Attempt = try backend.attempt(auth, &conversation);
            try conversation.checkCancelled();
            if (attempt.outcome != .failure) {
                try conversation.complete();
            } else {
                const still_allowed = if (attempt.remaining) |remaining| remaining.contains(method) else false;
                const retry_password = config.interaction != null and method == .password and still_allowed;
                const retry_key = config.interaction != null and method == .private_key and attempt.key_unlock_failed;
                const retry_keyboard = config.interaction != null and method == .keyboard_interactive and conversation.last != null and still_allowed;
                if (retry_password or retry_key or retry_keyboard) _ = try conversation.reject() else try conversation.complete();
                if (retry_password) {
                    prompt_password = true;
                    continue;
                }
                if (retry_key) {
                    prompt_passphrase = true;
                    continue;
                }
                if (retry_keyboard) continue;
            }
            var remaining_values: [4]policy.AuthMethod = undefined;
            var remaining_count: usize = 0;
            if (attempt.remaining) |remaining| {
                for (std.enums.values(policy.AuthMethod)) |value| if (remaining.contains(value)) {
                    remaining_values[remaining_count] = value;
                    remaining_count += 1;
                };
                try machine.resultWithRemaining(method, attempt.outcome, remaining_values[0..remaining_count]);
            } else try machine.result(method, attempt.outcome);
            if (machine.state == .authenticated) return .{ .accepted_methods = machine.completed };
            break;
        }
    }
    return error.AuthenticationFailed;
}
