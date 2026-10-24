const std = @import("std");
const provider = @import("provider.zig");
const registry = @import("registry.zig");
const app_config = @import("../config/config.zig");

pub const default_endpoint = "https://token-plan-cn.xiaomimimo.com/v1/chat/completions";
pub const default_model = "mimo-v2.6-flash";

/// A provider's configured name (or kind tag) and a model's full ID, never array indexes.
/// Slices are borrowed; assistant_store.Controls owns copies for per-owner overrides.
pub const ModelSelection = struct {
    provider_id: []const u8,
    model_id: []const u8,

    pub fn eql(self: ModelSelection, other: ModelSelection) bool {
        return std.mem.eql(u8, self.provider_id, other.provider_id) and std.mem.eql(u8, self.model_id, other.model_id);
    }
};

pub const Auth = union(enum) {
    none,
    bearer_memory: []const u8,
    anthropic_memory: []const u8,

    pub fn value(self: Auth) ?[]const u8 {
        return switch (self) {
            .bearer_memory, .anthropic_memory => |key| key,
            else => null,
        };
    }
};

/// The complete, non-owning provider selection used by runtime, transport and
/// request construction. Auth borrows a key loaded from App settings and
/// Keychain; callers own that lifetime.
pub const ProviderConfig = struct {
    kind: registry.Kind,
    endpoint: []const u8,
    model: []const u8,
    auth: Auth,
    context_window: u32 = 8192,
    vision: bool = false,
    /// Per-image admission reservation for a custom model with unknown local
    /// tokenization; never an assertion of actual provider usage.
    image_token_reservation: ?u32 = null,
    reasoning_wire: provider.ReasoningWire = .none,
    native_effort: bool = false,

    pub fn validate(self: ProviderConfig) !void {
        if (std.mem.trim(u8, self.endpoint, " \t\r\n").len == 0) return error.MissingEndpoint;
        if (std.mem.trim(u8, self.model, " \t\r\n").len == 0) return error.MissingModel;
        if (self.context_window == 0) return error.InvalidContextWindow;
        if (self.image_token_reservation) |value| if (!@import("image_budget.zig").validReservation(value)) return error.InvalidImageTokenReservation;
        switch (self.kind) {
            .anthropic => if (self.auth != .anthropic_memory) return error.InvalidAuth,
            .openai_compat => if (self.auth != .bearer_memory) return error.InvalidAuth,
            .ollama => if (self.auth != .none and self.auth != .bearer_memory) return error.InvalidAuth,
        }
    }

    /// Applies the configured model at the provider boundary, so callers do
    /// not need a second model/default source.
    pub fn chatRequest(self: ProviderConfig, request: provider.ChatRequest) provider.ChatRequest {
        var configured = request;
        configured.model = self.model;
        configured.vision = self.vision;
        configured.image_token_reservation = self.image_token_reservation;
        configured.reasoning_wire = self.reasoning_wire;
        configured.native_effort = self.native_effort;
        return configured;
    }
    pub fn supportsImageBudget(self: ProviderConfig) bool {
        return @import("image_budget.zig").supportsWithReservation(self.model, self.image_token_reservation);
    }
};

pub fn fromSettings(ai: app_config.Ai) !ProviderConfig {
    return fromSettingsSelection(ai, null);
}

/// A missing override uses the saved default. An explicit stale/disabled key
/// fails instead of switching to that default or another provider/model.
pub fn fromSettingsSelection(ai: app_config.Ai, selection: ?ModelSelection) !ProviderConfig {
    const resolved = try settingsModel(ai, selection);
    const p = resolved.provider;
    if (p.endpoint.len == 0) return error.MissingEndpoint;
    const auth: Auth = switch (p.kind) {
        .ollama => if (p.api_key.len == 0) .none else .{ .bearer_memory = p.api_key },
        .anthropic => if (p.api_key.len == 0) return error.MissingApiKey else .{ .anthropic_memory = p.api_key },
        .openai_compat => if (p.api_key.len == 0) return error.MissingApiKey else .{ .bearer_memory = p.api_key },
    };
    const result = ProviderConfig{ .kind = p.kind, .endpoint = p.endpoint, .model = resolved.model.id, .auth = auth, .context_window = resolved.model.context_window, .vision = resolved.model.vision, .image_token_reservation = resolved.model.image_token_reservation, .native_effort = resolved.model.reasoning_discovered, .reasoning_wire = if (p.kind == .anthropic and resolved.model.reasoning_adaptive) .anthropic_adaptive else toggleProtocol(p.kind, p.endpoint, resolved.model.id) };
    try result.validate();
    return result;
}

pub fn providerId(value: app_config.AiProvider) []const u8 {
    return if (value.name.len != 0) value.name else @tagName(value.kind);
}

/// Provider protocol names do not imply model capability. Legacy model-only
/// configuration has no declared reasoning/effort capability.
pub fn supportsEffort(ai: app_config.Ai, selection: ?ModelSelection, effort: provider.Effort) !bool {
    const resolved = try settingsModel(ai, selection);
    return (resolved.provider.kind == .openai_compat or resolved.model.reasoning_discovered) and resolved.model.reasoning and resolved.model.efforts[@backingInt(effort)];
}

pub fn validateEffort(ai: app_config.Ai, selection: ?ModelSelection, effort: provider.Effort) !void {
    if (!try supportsEffort(ai, selection, effort)) return error.UnsupportedEffort;
}

const SettingsModel = struct { provider: app_config.AiProvider, model: app_config.AiModel };

fn settingsModel(ai: app_config.Ai, selection: ?ModelSelection) !SettingsModel {
    if (ai.provider_count > ai.providers.len) return error.InvalidProviderCount;
    const requested_provider = if (selection) |key| key.provider_id else ai.default_provider;
    var selected: ?app_config.AiProvider = null;
    for (ai.providers[0..ai.provider_count]) |candidate| {
        if (std.mem.eql(u8, providerId(candidate), requested_provider)) {
            if (selected != null) return error.AmbiguousProvider;
            selected = candidate;
        }
    }
    const p = selected orelse return if (selection != null) error.UnknownProvider else error.MissingProviderConfiguration;
    if (!p.enabled) return error.ProviderDisabled;
    if (p.model_count > p.models.len) return error.InvalidModelCount;
    var model: ?app_config.AiModel = null;
    if (selection) |key| {
        for (p.models[0..p.model_count]) |candidate| {
            if (std.mem.eql(u8, candidate.id, key.model_id)) {
                if (model != null) return error.AmbiguousModel;
                model = candidate;
            }
        }
        if (model == null and p.models.len == 0 and p.model.len != 0 and std.mem.eql(u8, p.model, key.model_id)) {
            model = legacyModel(p);
        }
        if (model == null) return error.UnknownModel;
    } else {
        // Preserve the legacy saved-default rule when there is no owner override.
        for (p.models[0..p.model_count]) |candidate| {
            if (candidate.default or model == null) model = candidate;
            if (candidate.default) break;
        }
        if (model == null and p.model.len != 0) model = legacyModel(p);
    }
    const result = model orelse return error.MissingModel;
    if (std.mem.trim(u8, result.id, " \t\r\n").len == 0) return error.MissingModel;
    if (result.context_window == 0) return error.InvalidContextWindow;
    return .{ .provider = p, .model = result };
}

fn legacyModel(value: app_config.AiProvider) app_config.AiModel {
    return .{ .id = value.model, .context_window = value.context_window, .efforts = @splat(false) };
}

pub fn defaults(kind: registry.Kind) ProviderConfig {
    return switch (kind) {
        .anthropic => .{
            .kind = .anthropic,
            .endpoint = "https://api.anthropic.com/v1/messages",
            .model = "claude-sonnet-4-5",
            .auth = .{ .anthropic_memory = "" },
        },
        .openai_compat => .{
            .kind = .openai_compat,
            .endpoint = default_endpoint,
            .model = default_model,
            .auth = .{ .bearer_memory = "" },
        },
        .ollama => .{
            .kind = .ollama,
            .endpoint = "http://127.0.0.1:11434/api/chat",
            .model = "llama3.2",
            .auth = .none,
        },
    };
}

test "provider defaults never supply implicit credentials" {
    try std.testing.expectEqualStrings("", defaults(.openai_compat).auth.value().?);
    try std.testing.expectEqualStrings("", defaults(.anthropic).auth.value().?);
    try std.testing.expect(defaults(.ollama).auth == .none);
}

test "provider config is the request model source" {
    const config = defaults(.openai_compat);
    const request = config.chatRequest(.{ .model = "stale-caller-default", .effort = .low, .system = "", .messages = &.{} });
    try std.testing.expectEqualStrings(default_model, request.model);
}

test "settings resolve selected provider and default model without invented fallback" {
    var models = [_]app_config.AiModel{.{ .id = "m2", .context_window = 32768, .default = true }};
    var providers = [_]app_config.AiProvider{.{ .name = "custom", .kind = .openai_compat, .endpoint = "https://example.test/v1", .api_key = "secret", .enabled = true, .model_count = 1, .models = &models }};
    const ai = app_config.Ai{ .default_provider = "custom", .provider_count = 1, .providers = &providers };
    const resolved = try fromSettings(ai);
    try std.testing.expectEqualStrings("m2", resolved.model);
    try std.testing.expectEqual(@as(u32, 32768), resolved.context_window);
    try std.testing.expectEqualStrings("secret", resolved.auth.value().?);
}

test "settings reject unconfigured selection" {
    var providers = [_]app_config.AiProvider{.{ .kind = .openai_compat }};
    const ai = app_config.Ai{ .default_provider = "openai_compat", .provider_count = 1, .providers = &providers };
    try std.testing.expectError(error.ProviderDisabled, fromSettings(ai));
}

test "settings selection resolves exact provider model context and auth without changing saved defaults" {
    var first_models = [_]app_config.AiModel{.{ .id = "shared", .context_window = 200000, .default = true }};
    var second_models = [_]app_config.AiModel{
        .{ .id = "default", .context_window = 8192, .default = true },
        .{ .id = "shared", .context_window = 64000, .reasoning = true, .efforts = .{ true, false, false, true, false } },
    };
    var providers = [_]app_config.AiProvider{
        .{ .name = "cloud", .kind = .anthropic, .enabled = true, .endpoint = "https://cloud.test/messages", .api_key = "cloud-key", .model_count = 1, .models = &first_models },
        .{ .name = "gateway", .kind = .openai_compat, .enabled = true, .endpoint = "https://gateway.test/chat/completions", .api_key = "gateway-key", .model_count = 2, .models = &second_models },
    };
    const ai: app_config.Ai = .{ .default_provider = "cloud", .provider_count = 2, .providers = &providers };
    const key: ModelSelection = .{ .provider_id = "gateway", .model_id = "shared" };
    const result = try fromSettingsSelection(ai, key);
    try std.testing.expectEqualStrings("https://gateway.test/chat/completions", result.endpoint);
    try std.testing.expectEqualStrings("shared", result.model);
    try std.testing.expectEqual(@as(u32, 64000), result.context_window);
    try std.testing.expect(result.auth == .bearer_memory);
    try std.testing.expectEqualStrings("gateway-key", result.auth.value().?);
    try std.testing.expectEqualStrings("cloud", ai.default_provider);
    try std.testing.expect(second_models[0].default and !second_models[1].default);
    const saved = try fromSettingsSelection(ai, null);
    try std.testing.expectEqual(registry.Kind.anthropic, saved.kind);
    try std.testing.expectEqualStrings("cloud-key", saved.auth.value().?);
    try std.testing.expectEqual(@as(u32, 200000), saved.context_window);
}

test "settings selection rejects deleted disabled ambiguous and out of count keys without fallback" {
    var models = [_]app_config.AiModel{
        .{ .id = "saved-default", .context_window = 8192, .default = true },
        .{ .id = "chosen", .context_window = 32000 },
    };
    var providers = [_]app_config.AiProvider{
        .{ .name = "lab", .kind = .ollama, .enabled = true, .endpoint = "http://localhost:11434/api/chat", .model_count = 2, .models = &models },
        .{ .name = "hidden", .kind = .ollama, .enabled = true, .endpoint = "http://localhost:11434/api/chat", .model_count = 1, .models = models[0..1] },
    };
    var ai: app_config.Ai = .{ .default_provider = "lab", .provider_count = 1, .providers = &providers };
    const key: ModelSelection = .{ .provider_id = "lab", .model_id = "chosen" };
    _ = try fromSettingsSelection(ai, key);
    try std.testing.expectError(error.UnknownProvider, fromSettingsSelection(ai, .{ .provider_id = "hidden", .model_id = "saved-default" }));
    providers[0].model_count = 1;
    try std.testing.expectError(error.UnknownModel, fromSettingsSelection(ai, key));
    providers[0].model_count = 2;
    models[1].id = "renamed";
    try std.testing.expectError(error.UnknownModel, fromSettingsSelection(ai, key));
    providers[0].enabled = false;
    try std.testing.expectError(error.ProviderDisabled, fromSettingsSelection(ai, key));
    providers[0].enabled = true;
    providers[0].name = "renamed-provider";
    try std.testing.expectError(error.UnknownProvider, fromSettingsSelection(ai, key));
    providers[0].name = "lab";
    models[1].id = "saved-default";
    try std.testing.expectError(error.AmbiguousModel, fromSettingsSelection(ai, .{ .provider_id = "lab", .model_id = "saved-default" }));
    providers[1].name = "lab";
    ai.provider_count = 2;
    try std.testing.expectError(error.AmbiguousProvider, fromSettingsSelection(ai, key));
    ai.provider_count = 3;
    try std.testing.expectError(error.InvalidProviderCount, fromSettingsSelection(ai, key));
    ai.provider_count = 1;
    providers[0].model_count = 3;
    try std.testing.expectError(error.InvalidModelCount, fromSettingsSelection(ai, key));
}

test "settings selection effort validation reads actual reasoning and declared subset" {
    var models = [_]app_config.AiModel{
        .{ .id = "limited", .context_window = 8192, .default = true, .reasoning = true, .efforts = .{ true, false, true, false, false } },
        .{ .id = "quiet", .context_window = 8192, .reasoning = false, .efforts = @splat(true) },
    };
    var providers = [_]app_config.AiProvider{.{ .kind = .openai_compat, .enabled = true, .name = "ollama", .endpoint = "https://example.test/chat", .api_key = "saved", .model_count = 2, .models = &models }};
    const ai: app_config.Ai = .{ .default_provider = "ollama", .provider_count = 1, .providers = &providers };
    const key: ModelSelection = .{ .provider_id = "ollama", .model_id = "limited" };
    try std.testing.expect(try supportsEffort(ai, key, .low));
    try std.testing.expect(try supportsEffort(ai, null, .high));
    try validateEffort(ai, key, .high);
    try std.testing.expectError(error.UnsupportedEffort, validateEffort(ai, key, .medium));
    try std.testing.expect(!try supportsEffort(ai, .{ .provider_id = "ollama", .model_id = "quiet" }, .high));
    models[0].efforts = @splat(false);
    try std.testing.expectError(error.UnsupportedEffort, validateEffort(ai, key, .low));
    try std.testing.expectError(error.UnknownModel, supportsEffort(ai, .{ .provider_id = "ollama", .model_id = "deleted" }, .low));
    try std.testing.expectEqualStrings("ollama", providerId(providers[0]));
    providers[0].models = @constCast(&[_]app_config.AiModel{});
    providers[0].model_count = 0;
    providers[0].model = "legacy";
    providers[0].context_window = 4096;
    const legacy: ModelSelection = .{ .provider_id = "ollama", .model_id = "legacy" };
    try std.testing.expectEqualStrings("legacy", (try fromSettingsSelection(ai, legacy)).model);
    try std.testing.expect(!try supportsEffort(ai, legacy, .high));
    try std.testing.expectError(error.UnknownModel, fromSettingsSelection(ai, key));
}

test "configured chat model preserves tool declarations calls results and request control pointers" {
    const definitions = [_]provider.ToolDefinition{.{ .tool = .run_command, .session_ids = &.{101} }};
    const calls = [_]provider.ToolCall{.{ .id = "original-call", .name = "run_command", .arguments = "{\"session_ids\":[101],\"command\":\"df -h\"}" }};
    const messages = [_]provider.Message{
        .{ .role = .assistant, .content = "", .tool_calls = &calls },
        .{ .role = .tool, .content = "actual output", .tool_call_id = "original-call" },
    };
    var token: provider.CancelToken = .{};
    var hint: ?u32 = null;
    const request: provider.ChatRequest = .{ .model = "caller-model", .system = "frozen scope", .messages = &messages, .tools = &definitions, .effort = .high, .cancel = &token, .retry_after_ms = &hint, .timeout_ms = 1234 };
    var config = defaults(.openai_compat);
    config.model = "selected-model";
    const configured = config.chatRequest(request);
    try std.testing.expectEqualStrings("selected-model", configured.model);
    try std.testing.expect(configured.tools.ptr == request.tools.ptr);
    try std.testing.expect(configured.messages.ptr == request.messages.ptr);
    try std.testing.expectEqualStrings("original-call", configured.messages[0].tool_calls[0].id);
    try std.testing.expectEqualStrings("original-call", configured.messages[1].tool_call_id.?);
    try std.testing.expect(configured.cancel == &token and configured.retry_after_ms == &hint);
    try std.testing.expectEqual(@as(u32, 1234), configured.timeout_ms);
    try std.testing.expectEqual(provider.Effort.high, configured.effort.?);
}

test "API2 configured image reservations reject invalid values and do not infer unknown budgets" {
    var config = defaults(.openai_compat);
    config.model = "custom/vision-model";
    config.vision = true;
    try std.testing.expect(!config.supportsImageBudget());
    config.image_token_reservation = 1024;
    try config.validate();
    const configured = config.chatRequest(.{ .model = "caller-model", .system = "", .messages = &.{} });
    try std.testing.expectEqual(@as(?u32, 1024), configured.image_token_reservation);
    try std.testing.expect(config.supportsImageBudget());
    config.image_token_reservation = 0;
    try std.testing.expectError(error.InvalidImageTokenReservation, config.validate());
    try std.testing.expect(!config.supportsImageBudget());
    config.image_token_reservation = 131073;
    try std.testing.expectError(error.InvalidImageTokenReservation, config.validate());
    config.image_token_reservation = null;
    config.model = "gpt-4o";
    try std.testing.expect(config.supportsImageBudget());
}

test "native adapter capabilities reject unverified effort while Ollama retains optional gateway authentication" {
    var models = [_]app_config.AiModel{.{ .id = "native-model", .context_window = 8192, .reasoning = true, .efforts = @splat(true) }};
    var providers = [_]app_config.AiProvider{.{ .name = "native", .kind = .ollama, .enabled = true, .endpoint = "http://127.0.0.1:8080/api/chat", .api_key = "private-key", .model_count = 1, .models = &models }};
    const ai: app_config.Ai = .{ .default_provider = "native", .provider_count = 1, .providers = &providers };
    const authenticated = try fromSettings(ai);
    try std.testing.expectEqualStrings("private-key", authenticated.auth.value().?);
    try std.testing.expect(authenticated.auth == .bearer_memory);
    providers[0].api_key = "";
    try std.testing.expect((try fromSettings(ai)).auth == .none);
    for ([_]registry.Kind{ .anthropic, .ollama }) |kind| {
        providers[0].kind = kind;
        for (std.enums.values(provider.Effort)) |effort| {
            try std.testing.expect(!try supportsEffort(ai, null, effort));
            try std.testing.expectError(error.UnsupportedEffort, validateEffort(ai, null, effort));
        }
    }
}

/// Model capability and wire protocol are resolved separately.
pub fn toggleProtocol(kind: registry.Kind, endpoint: []const u8, model: []const u8) provider.ReasoningWire {
    if (kind == .ollama) return .ollama;
    if (kind != .openai_compat) return .none;
    const uri = std.Uri.parse(endpoint) catch return .none;
    const host = uri.host orelse return .none;
    const h = switch (host) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
    if (std.ascii.eqlIgnoreCase(h, "openrouter.ai")) return .openrouter;
    const bare = if (std.mem.lastIndexOfScalar(u8, model, '/')) |i| model[i + 1 ..] else model;
    if (std.ascii.startsWithIgnoreCase(bare, "mimo-v2.")) return .thinking_type;
    return .none;
}
pub fn supportsThinking(ai: app_config.Ai, selection: ?ModelSelection) !bool {
    const resolved = try settingsModel(ai, selection);
    return resolved.model.reasoning and resolved.model.reasoning_toggle and (resolved.model.reasoning_adaptive or toggleProtocol(resolved.provider.kind, resolved.provider.endpoint, resolved.model.id) != .none);
}
