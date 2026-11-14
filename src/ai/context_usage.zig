//! A provider input measurement is valid only for its exact request prefix.
//! Output usage may include reasoning that is not replayed, so estimate only
//! the assistant content actually retained after that measured prefix.
const std = @import("std");
const provider = @import("provider.zig");
const budget = @import("local_text_request.zig");
const Config = @import("provider_config.zig").ProviderConfig;

pub const Fixed = struct {
    fingerprint: u64 = 0,
    system_tokens: usize = 0,
    tool_tokens: usize = 0,
    pub fn capture(request: provider.ChatRequest) !Fixed {
        var hash = std.hash.Wyhash.init(0);
        hashText(&hash, request.system);
        std.hash.autoHash(&hash, request.tools.len);
        for (request.tools) |tool| {
            std.hash.autoHash(&hash, tool.tool);
            std.hash.autoHash(&hash, tool.session_ids.len);
            for (tool.session_ids) |id| std.hash.autoHash(&hash, id);
            std.hash.autoHash(&hash, tool.dynamic != null);
            if (tool.dynamic) |dynamic| {
                hashText(&hash, dynamic.id);
                hashText(&hash, dynamic.name);
                hashText(&hash, dynamic.description);
                hashText(&hash, dynamic.schema);
            }
        }
        return .{ .fingerprint = hash.final(), .system_tokens = budget.textTokens(request.system.len), .tool_tokens = try budget.toolTokens(request.tools) };
    }
    pub fn tokens(self: Fixed) usize {
        return self.system_tokens +| self.tool_tokens;
    }
};

pub const Sources = struct {
    system: usize = 0,
    tools: usize = 0,
    messages: usize = 0,
    images: usize = 0,
    unattributed: usize = 0,

    pub fn total(self: Sources) usize {
        return self.system +| self.tools +| self.messages +| self.images +| self.unattributed;
    }

    /// The provider reports total input, not per-source token counts. The
    /// estimates explain part of that total without adding anything to it.
    pub fn fitMeasured(self: Sources, measured: usize) Sources {
        const estimated = self.total();
        var result = self;
        if (estimated <= measured) {
            result.unattributed += measured - estimated;
            return result;
        }
        var consumed: u128 = 0;
        var previous: usize = 0;
        inline for (@typeInfo(Sources).@"struct".field_names) |field| {
            consumed += @field(self, field);
            const boundary: usize = @intCast(@min(consumed, estimated) * measured / estimated);
            @field(result, field) = boundary - previous;
            previous = boundary;
        }
        return result;
    }

    pub fn measuredInput(request: provider.ChatRequest, fixed: Fixed, measured: usize) Sources {
        // A conservative image admission reserve is not a token estimate.
        // Leave those tokens inside the provider's unattributed difference.
        const images = @import("image_budget.zig");
        const estimate: Sources = .{
            .system = fixed.system_tokens,
            .tools = fixed.tool_tokens,
            .messages = budget.messageTextTokens(request.messages) catch 0,
            .images = if (images.supports(request.model)) images.validate(request) catch 0 else 0,
        };
        return estimate.fitMeasured(measured);
    }
};
pub const Sample = struct {
    input_tokens: usize,
    prefix_count: usize,
    prefix_hash: u64,
    fixed: Fixed,
    sources: ?Sources = null,
    pub fn capture(request: provider.ChatRequest, input_tokens: u32) !Sample {
        const fixed = try Fixed.capture(request);
        return .{ .input_tokens = input_tokens, .prefix_count = request.messages.len, .prefix_hash = prefixHash(request.messages), .fixed = fixed, .sources = Sources.measuredInput(request, fixed, input_tokens) };
    }
    pub fn matches(self: Sample, messages: []const provider.Message) bool {
        return self.prefix_count <= messages.len and self.prefix_hash == prefixHash(messages[0..self.prefix_count]);
    }
};
pub const Baseline = struct { sample: Sample, model_key: u64 };

/// Durable counter metadata only; history/model validation grants no authority.
/// The full history stamp also detects edits to content after the measured prefix.
pub const Stored = struct {
    version: u8 = 1,
    baseline: Baseline,
    history_count: usize,
    history_hash: u64,
    pub fn capture(messages: []const provider.Message, baseline: ?Baseline) ?Stored {
        const value = baseline orelse return null;
        if (value.sample.input_tokens == 0 or !value.sample.matches(messages)) return null;
        return .{ .baseline = value, .history_count = messages.len, .history_hash = prefixHash(messages) };
    }
    /// Model identity is checked by Cache.readWithFixed against the selected
    /// provider configuration before this restored candidate can be displayed.
    pub fn restore(self: Stored, messages: []const provider.Message) ?Baseline {
        if (self.version != 1 or self.history_count != messages.len or self.history_hash != prefixHash(messages)) return null;
        if (self.baseline.sample.input_tokens == 0 or !self.baseline.sample.matches(messages)) return null;
        return self.baseline;
    }
};

pub fn modelKey(model: Config) u64 {
    var hash = std.hash.Wyhash.init(0);
    hashText(&hash, model.endpoint);
    hashText(&hash, model.model);
    std.hash.autoHash(&hash, .{ model.kind, model.vision, model.image_token_reservation, model.image_token_max_width, model.image_token_max_height, model.reasoning_wire, model.native_effort });
    return hash.final();
}
fn hashText(hash: *std.hash.Wyhash, text: []const u8) void {
    std.hash.autoHash(hash, text.len);
    hash.update(text);
}
pub fn prefixHash(messages: []const provider.Message) u64 {
    var hash = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hash, messages.len);
    for (messages) |message| {
        std.hash.autoHash(&hash, message.role);
        hashText(&hash, message.content);
        std.hash.autoHash(&hash, message.tool_call_id != null);
        if (message.tool_call_id) |id| hashText(&hash, id);
        std.hash.autoHash(&hash, message.tool_calls.len);
        for (message.tool_calls) |call| {
            hashText(&hash, call.id);
            hashText(&hash, call.name);
            hashText(&hash, call.arguments);
        }
        std.hash.autoHash(&hash, .{ message.images.len, message.image_owner, message.image_transform });
        for (message.images) |image| if (image.content()) |content| hash.update(&content.sha256);
    }
    return hash.final();
}

test "durable context usage validates complete history including content after the measured prefix" {
    const request: provider.ChatRequest = .{ .model = "fixture", .system = "system", .messages = &.{.{ .content = "question" }} };
    const model: Config = .{ .kind = .openai_compat, .endpoint = "http://127.0.0.1:9", .model = "fixture", .auth = .none };
    const baseline: Baseline = .{ .sample = try Sample.capture(request, 12000), .model_key = modelKey(model) };
    const history = [_]provider.Message{ request.messages[0], .{ .role = .assistant, .content = "answer" } };
    const stored = Stored.capture(&history, baseline).?;
    try std.testing.expect(stored.restore(&history) != null);
    const edited_tail = [_]provider.Message{ request.messages[0], .{ .role = .assistant, .content = "edited" } };
    try std.testing.expect(stored.restore(&edited_tail) == null);
    try std.testing.expect(stored.restore(history[0..1]) == null);
    var unsupported = stored;
    unsupported.version = 2;
    try std.testing.expect(unsupported.restore(&history) == null);
    var invalid_prefix = stored;
    invalid_prefix.baseline.sample.prefix_hash +%= 1;
    try std.testing.expect(invalid_prefix.restore(&history) == null);
}
