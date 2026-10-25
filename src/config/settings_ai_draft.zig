//! Provider form state belongs to the shared settings draft, not its mounted page.
const std = @import("std");
const config = @import("config.zig");

pub const Field = enum { name, endpoint, api_key, model_id, context_window };
pub const Address = struct {
    provider: usize,
    model: usize = 0,
    field: Field,
    pub fn eql(a: Address, b: Address) bool {
        return a.provider == b.provider and a.model == b.model and a.field == b.field;
    }
};
pub const Raw = struct { address: Address, input: []u8, problem: ?anyerror = null };
pub const State = struct {
    fields: std.ArrayList(Raw) = .empty,
    provider_open: std.AutoHashMapUnmanaged(usize, bool) = .empty,
    connection_open: std.AutoHashMapUnmanaged(usize, bool) = .empty,
    model_open: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    new_provider: ?usize = null,
    new_model: ?struct { provider: usize, model: usize } = null,
    existing_open: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clearRaw(allocator);
        self.fields.deinit(allocator);
        self.provider_open.deinit(allocator);
        self.connection_open.deinit(allocator);
        self.model_open.deinit(allocator);
    }
    pub fn clearRaw(self: *State, allocator: std.mem.Allocator) void {
        for (self.fields.items) |raw| allocator.free(raw.input);
        self.fields.clearRetainingCapacity();
        self.new_provider = null;
        self.new_model = null;
    }
    pub fn get(self: *const State, address: Address) ?Raw {
        for (self.fields.items) |raw| if (raw.address.eql(address)) return raw;
        return null;
    }
    pub fn put(self: *State, allocator: std.mem.Allocator, address: Address, text: []const u8) !*Raw {
        const owned = try allocator.dupe(u8, text);
        errdefer allocator.free(owned);
        for (self.fields.items) |*raw| if (raw.address.eql(address)) {
            allocator.free(raw.input);
            raw.* = .{ .address = address, .input = owned };
            return raw;
        };
        try self.fields.append(allocator, .{ .address = address, .input = owned });
        return &self.fields.items[self.fields.items.len - 1];
    }
    pub fn remove(self: *State, allocator: std.mem.Allocator, address: Address) void {
        for (self.fields.items, 0..) |raw, index| if (raw.address.eql(address)) {
            allocator.free(raw.input);
            _ = self.fields.orderedRemove(index);
            return;
        };
    }
    pub fn invalid(self: *const State) bool {
        for (self.fields.items) |raw| if (raw.problem != null) return true;
        return false;
    }
    pub fn removeModel(self: *State, allocator: std.mem.Allocator, provider: usize, model: usize) void {
        var i: usize = 0;
        while (i < self.fields.items.len) {
            const raw = &self.fields.items[i];
            if (raw.address.provider == provider and (raw.address.field == .model_id or raw.address.field == .context_window)) {
                if (raw.address.model == model) {
                    allocator.free(raw.input);
                    _ = self.fields.orderedRemove(i);
                    continue;
                }
                if (raw.address.model > model) raw.address.model -= 1;
            }
            i += 1;
        }
        self.model_open.clearRetainingCapacity();
        if (self.new_model) |new| if (new.provider == provider and new.model == model) {
            self.new_model = null;
        } else if (new.provider == provider and new.model > model) {
            self.new_model.?.model -= 1;
        };
    }
    pub fn removeProvider(self: *State, allocator: std.mem.Allocator, provider: usize) void {
        var i: usize = 0;
        while (i < self.fields.items.len) {
            const raw = &self.fields.items[i];
            if (raw.address.provider == provider) {
                allocator.free(raw.input);
                _ = self.fields.orderedRemove(i);
                continue;
            }
            if (raw.address.provider > provider) raw.address.provider -= 1;
            i += 1;
        }
        self.provider_open.clearRetainingCapacity();
        self.connection_open.clearRetainingCapacity();
        self.model_open.clearRetainingCapacity();
        if (self.new_provider) |index| {
            if (index == provider) self.new_provider = null else if (index > provider) self.new_provider = index - 1;
        }
        if (self.new_model) |new| {
            if (new.provider == provider) self.new_model = null else if (new.provider > provider) self.new_model.?.provider -= 1;
        }
    }
};

pub fn modelKey(provider: usize, model: usize) u64 {
    return (@as(u64, @intCast(provider)) << 32) | @as(u64, @intCast(model));
}
pub fn providerName(p: config.AiProvider) []const u8 {
    return if (p.name.len != 0) p.name else @tagName(p.kind);
}
pub fn endpointValid(text: []const u8) bool {
    if (text.len == 0 or std.mem.indexOfAny(u8, text, " \t\r\n\x00") != null) return false;
    const uri = std.Uri.parse(text) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return false;
    if (uri.user != null or uri.password != null or uri.fragment != null) return false;
    const host = uri.host orelse return false;
    return switch (host) {
        .raw => |value| value.len != 0,
        .percent_encoded => |value| value.len != 0,
    };
}
pub fn fieldValue(ai: config.Ai, address: Address, buffer: []u8) ![]const u8 {
    if (address.provider >= ai.provider_count) return error.UnknownProvider;
    const p = ai.providers[address.provider];
    return switch (address.field) {
        .name => p.name,
        .endpoint => p.endpoint,
        .api_key => p.api_key,
        .model_id => if (address.model < p.model_count) p.models[address.model].id else "",
        .context_window => if (address.model < p.model_count) std.fmt.bufPrint(buffer, "{d}", .{p.models[address.model].context_window}) else "",
    };
}
pub fn assign(ai: *config.Ai, address: Address, text: []const u8) !void {
    if (address.provider >= ai.provider_count) return error.UnknownProvider;
    const p = &ai.providers[address.provider];
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.indexOfAny(u8, text, "\x00\"\\\n\r;#") != null) return error.InvalidText;
    switch (address.field) {
        .name => {
            if (trimmed.len == 0) return error.EmptyProviderName;
            for (ai.providers[0..ai.provider_count], 0..) |other, i| if (i != address.provider and std.mem.eql(u8, providerName(other), trimmed)) return error.DuplicateProviderName;
            var was_default = false;
            for (ai.providers[0..ai.provider_count], 0..) |candidate, index| if (std.mem.eql(u8, ai.default_provider, providerName(candidate))) {
                was_default = index == address.provider;
                break;
            };
            p.name = trimmed;
            if (was_default) ai.default_provider = trimmed;
        },
        .endpoint => {
            if (trimmed.len != 0 and !endpointValid(trimmed)) return error.InvalidEndpoint;
            p.endpoint = trimmed;
        },
        .api_key => p.api_key = text,
        .model_id => {
            if (address.model >= p.model_count) return error.UnknownModel;
            if (trimmed.len == 0) return error.EmptyModelId;
            for (p.models[0..p.model_count], 0..) |m, j| if (j != address.model and std.mem.eql(u8, m.id, trimmed)) return error.DuplicateModelId;
            p.models[address.model].id = trimmed;
        },
        .context_window => {
            if (address.model >= p.model_count) return error.UnknownModel;
            const window = std.fmt.parseInt(u32, trimmed, 10) catch return error.InvalidContextWindow;
            if (window == 0) return error.InvalidContextWindow;
            p.models[address.model].context_window = window;
        },
    }
}

/// Configuration edits never enable a provider. The explicit switch owns that transition.
pub fn setEnabled(ai: *config.Ai, index: usize, enabled: bool) !void {
    if (index >= ai.provider_count) return error.UnknownProvider;
    const p = &ai.providers[index];
    if (enabled) {
        if (std.mem.trim(u8, p.name, " \t\r\n").len == 0) return error.EmptyProviderName;
        if (!eligible(p.*)) return error.IncompleteProvider;
        p.enabled = true;
        var valid_default = false;
        for (ai.providers[0..ai.provider_count]) |other| if (other.enabled and eligible(other) and std.mem.eql(u8, providerName(other), ai.default_provider)) {
            valid_default = true;
        };
        if (!valid_default) ai.default_provider = providerName(p.*);
        return;
    }
    if (std.mem.eql(u8, ai.default_provider, providerName(p.*))) {
        var replacement: ?[]const u8 = null;
        for (ai.providers[0..ai.provider_count], 0..) |other, i| if (i != index and other.enabled and eligible(other)) {
            replacement = providerName(other);
            break;
        };
        ai.default_provider = replacement orelse return error.DefaultProtected;
    }
    p.enabled = false;
}
pub fn modelValid(model: config.AiModel) bool {
    if (std.mem.trim(u8, model.id, " \t\r\n").len == 0 or model.context_window == 0) return false;
    if (model.reasoning and !model.reasoning_toggle) {
        for (model.efforts) |enabled| if (enabled) return true;
        return false;
    }
    return true;
}
pub fn eligible(p: config.AiProvider) bool {
    if (!endpointValid(p.endpoint) or p.model_count == 0 or p.model_count > p.models.len or (p.api_key.len == 0 and !@import("../ai/provider_config.zig").allowsNoAuth(p.kind, p.endpoint))) return false;
    for (p.models[0..p.model_count]) |model| if (!modelValid(model)) return false;
    return true;
}
pub fn validate(ai: config.Ai) !void {
    if (ai.provider_count > ai.providers.len) return error.InvalidProviderCount;
    var any_enabled = false;
    var default_found = false;
    for (ai.providers[0..ai.provider_count], 0..) |p, i| {
        if (p.model_count > p.models.len) return error.InvalidModelCount;
        for (ai.providers[0..i]) |other| if (std.mem.eql(u8, providerName(p), providerName(other))) return error.DuplicateProviderName;
        if (!p.enabled) continue;
        for (p.models[0..p.model_count], 0..) |model, j| {
            if (!modelValid(model)) return error.InvalidModel;
            for (p.models[0..j]) |other| if (std.mem.eql(u8, model.id, other.id)) return error.DuplicateModelId;
        }
        if (!eligible(p)) return error.IncompleteProvider;
        var default_models: usize = 0;
        for (p.models[0..p.model_count]) |model| if (model.default) {
            default_models += 1;
        };
        if (default_models != 1) return error.InvalidDefaultModel;
        any_enabled = true;
        if (std.mem.eql(u8, providerName(p), ai.default_provider)) default_found = true;
    }
    if (any_enabled and !default_found) return error.InvalidDefaultProvider;
}
pub fn validateDefault(ai: config.Ai, original: config.Ai) !void {
    var had_default = false;
    for (original.providers[0..original.provider_count]) |p| if (p.enabled and eligible(p) and std.mem.eql(u8, providerName(p), original.default_provider)) {
        had_default = true;
    };
    if (!had_default) return;
    for (ai.providers[0..ai.provider_count]) |p| if (p.enabled and eligible(p) and std.mem.eql(u8, providerName(p), ai.default_provider)) return;
    return error.DefaultProtected;
}
pub fn problemText(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyProviderName => "名称不能为空",
        error.DuplicateProviderName => "Provider 名称已存在",
        error.InvalidEndpoint => "需填写带主机的 HTTP/HTTPS 地址，不含账号、密码或片段",
        error.EmptyModelId => "模型 ID 不能为空",
        error.DuplicateModelId => "同一 Provider 内模型 ID 不能重复",
        error.InvalidContextWindow => "上下文窗口须为 1–4294967295 的整数",
        error.LastEffortRequired => "推理模型至少保留一个 effort 档位",
        error.DefaultProtected => "请先选择已有合法的默认替代项",
        error.IncompleteProvider => "请补齐连接信息和至少一个有效模型",
        error.InvalidText => "内容包含配置不支持的字符",
        else => "配置尚不完整，请检查当前字段",
    };
}
