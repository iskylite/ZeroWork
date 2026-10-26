//! Shared discovery metadata. Catalog capabilities never select a wire protocol.
const std = @import("std");
const Kind = @import("registry.zig").Kind;
pub const refresh_seconds = 24 * 60 * 60;
pub const Capability = struct {
    reasoning: ?bool = null,
    toggle: bool = false,
    control_known: bool = false,
    thinking_default: ?bool = null,
    adaptive: bool = false,
    efforts: [7]bool = @splat(false),
    context: ?u32 = null,
    vision: ?bool = null,
    pub fn hasControl(self: Capability) bool {
        return self.toggle or !std.mem.eql(bool, &self.efforts, &@as([7]bool, @splat(false)));
    }
};
pub const Entry = struct { provider: []const u8, id: []const u8, api: []const u8 = "", canonical: bool = false, capability: Capability };
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
    }
    pub fn parse(allocator: std.mem.Allocator, body: []const u8, format: enum { models_dev, openrouter, endpoint, ollama }) !Catalog {
        if (body.len > 32 * 1024 * 1024) return error.CatalogTooLarge;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const json = try std.json.parseFromSlice(std.json.Value, a, body, .{ .allocate = .alloc_always, .max_value_len = 1024 * 1024 });
        const root = json.value;
        if (root != .object) return error.InvalidCatalog;
        var entries: std.ArrayList(Entry) = .empty;
        if (format == .models_dev) {
            var providers = root.object.iterator();
            while (providers.next()) |p| {
                const models = field(p.value_ptr.*, "models") orelse continue;
                if (models != .object) continue;
                var it = models.object.iterator();
                while (it.next()) |m| try entries.append(a, .{ .provider = p.key_ptr.*, .api = string(field(p.value_ptr.*, "api")) orelse "", .canonical = canonicalProvider(p.key_ptr.*, m.value_ptr.*), .id = string(field(m.value_ptr.*, "id")) orelse m.key_ptr.*, .capability = metadata(m.value_ptr.*) });
            }
        } else {
            const list = field(root, if (format == .ollama) "models" else "data") orelse return error.InvalidCatalog;
            if (list != .array) return error.InvalidCatalog;
            for (list.array.items) |m| {
                const id = string(field(m, "id")) orelse string(field(m, "name")) orelse continue;
                const slash = std.mem.indexOfScalar(u8, id, '/');
                try entries.append(a, .{ .provider = string(field(m, "owned_by")) orelse (if (slash) |s| id[0..s] else ""), .id = id, .capability = metadata(m) });
            }
        }
        if (entries.items.len > 50000) return error.CatalogTooLarge;
        return .{ .arena = arena, .entries = try entries.toOwnedSlice(a) };
    }
    /// Exact provider is preferred. Unknown provider falls back to model names.
    /// Longest delimiter-bounded prefix wins; conflicting equal matches fail closed.
    pub fn resolve(self: Catalog, provider: []const u8, id: []const u8) ?Capability {
        var provider_known = false;
        for (self.entries) |e| if (provider.len != 0 and std.ascii.eqlIgnoreCase(e.provider, provider)) {
            provider_known = true;
            break;
        };
        var score: usize = 0;
        var result: ?Capability = null;
        var ambiguous = false;
        for (self.entries) |e| {
            if (provider_known and !std.ascii.eqlIgnoreCase(e.provider, provider)) continue;
            const match = matchScore(e.id, id);
            if (match == 0) continue;
            const rank = match * 2 + @intFromBool(e.canonical);
            if (rank == 0 or rank < score) continue;
            if (rank > score) {
                score = rank;
                result = e.capability;
                ambiguous = false;
            } else if (result) |previous| {
                if (!std.meta.eql(previous, e.capability)) ambiguous = true;
            }
        }
        return if (ambiguous) null else result;
    }
};
fn canonicalProvider(provider: []const u8, value: std.json.Value) bool {
    const id = string(field(value, "canonical_model_id")) orelse return false;
    const slash = std.mem.indexOfScalar(u8, id, '/') orelse return false;
    return std.ascii.eqlIgnoreCase(provider, id[0..slash]);
}
fn bare(id: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, id, '/')) |i| id[i + 1 ..] else id;
}
fn matchScore(candidate: []const u8, requested: []const u8) usize {
    if (std.ascii.eqlIgnoreCase(candidate, requested)) return 100000 + candidate.len;
    const c = bare(candidate);
    const r = bare(requested);
    if (std.ascii.eqlIgnoreCase(c, r)) return 90000 + c.len;
    if (r.len <= c.len or !std.ascii.eqlIgnoreCase(c, r[0..c.len])) return 0;
    return switch (r[c.len]) {
        '-', ':', '@', '.', '_' => c.len,
        else => 0,
    };
}
pub fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    return if (v == .object) v.object.get(key) else null;
}
fn string(v: ?std.json.Value) ?[]const u8 {
    return if (v) |x| if (x == .string) x.string else null else null;
}
fn boolean(v: ?std.json.Value) ?bool {
    return if (v) |x| if (x == .bool) x.bool else null else null;
}
fn integer(v: ?std.json.Value) ?u32 {
    return if (v) |x| if (x == .integer and x.integer > 0 and x.integer <= std.math.maxInt(u32)) @intCast(x.integer) else null else null;
}
pub fn metadata(v: std.json.Value) Capability {
    var c: Capability = .{ .reasoning = boolean(field(v, "reasoning")), .context = integer(field(v, "context_length")) orelse integer(field(v, "context_window")) orelse integer(field(v, "max_input_tokens")), .vision = boolean(field(v, "vision")) };
    c.control_known = c.reasoning != null and !c.reasoning.?;
    if (field(v, "thinking")) |thinking| if (field(thinking, "values")) |values| {
        if (values == .array) {
            c.control_known = true;
            var on = false;
            var off = false;
            for (values.array.items) |value| {
                if (value == .bool) {
                    if (value.bool) on = true else off = true;
                }
                if (value == .string) inline for (.{ "low", "medium", "high", "xhigh", "max", "none", "ultra" }, 0..) |label, i| {
                    if (std.mem.eql(u8, value.string, label)) c.efforts[i] = true;
                };
            }
            c.toggle = on and off;
            c.reasoning = on or c.hasControl();
            c.thinking_default = boolean(field(thinking, "default"));
        }
    };
    if (field(v, "capabilities")) |caps| {
        if (field(caps, "image_input")) |image| c.vision = boolean(field(image, "supported"));
        if (field(caps, "thinking")) |thinking| {
            c.reasoning = boolean(field(thinking, "supported"));
            if (field(thinking, "types")) |types| {
                if (field(types, "adaptive")) |adaptive| c.adaptive = boolean(field(adaptive, "supported")) orelse false;
                if (field(types, "disabled")) |disabled| c.toggle = boolean(field(disabled, "supported")) orelse false;
            }
        }
        if (field(caps, "effort")) |effort| {
            c.control_known = true;
            inline for (.{ "low", "medium", "high", "xhigh", "max", "none", "ultra" }, 0..) |label, i| {
                if (field(effort, label)) |level| c.efforts[i] = boolean(field(level, "supported")) orelse false;
            }
        }
    }
    if (field(v, "limit")) |limit| c.context = integer(field(limit, "context")) orelse c.context;
    if (field(v, "modalities")) |m| if (field(m, "input")) |input| {
        if (input == .array) {
            c.vision = false;
            for (input.array.items) |x| if (x == .string and std.mem.eql(u8, x.string, "image")) {
                c.vision = true;
            };
        }
    };
    if (field(v, "reasoning_options")) |options| if (options == .array) for (options.array.items) |option| {
        const kind = string(field(option, "type")) orelse continue;
        c.control_known = true;
        if (std.mem.eql(u8, kind, "toggle")) c.toggle = true;
        if (std.mem.eql(u8, kind, "effort")) if (field(option, "values")) |values| {
            if (values == .array) for (values.array.items) |value| {
                const name = string(value) orelse continue;
                inline for (.{ "low", "medium", "high", "xhigh", "max", "none", "ultra" }, 0..) |label, i| if (std.mem.eql(u8, name, label)) {
                    c.efforts[i] = true;
                };
            };
        };
    };
    // OpenAI-compatible gateways expose either string levels or records. Read
    // only declared levels; unknown future names must not enable another level.
    inline for (.{ "reasoning_levels", "supported_reasoning_levels" }) |key| {
        if (field(v, key)) |levels| if (levels == .array) {
            c.control_known = true;
            for (levels.array.items) |level| {
                const name = string(level) orelse string(field(level, "effort")) orelse continue;
                inline for (.{ "low", "medium", "high", "xhigh", "max", "none", "ultra" }, 0..) |label, i| {
                    if (std.mem.eql(u8, name, label)) c.efforts[i] = true;
                }
            }
        };
    }
    return c;
}
/// Preserve custom reverse-proxy base paths; remove only known protocol suffixes.
pub fn endpoint(allocator: std.mem.Allocator, base: []const u8, kind: Kind) ![]u8 {
    const query_at = std.mem.indexOfScalar(u8, base, '?') orelse base.len;
    const query = base[query_at..];
    var path = std.mem.trimEnd(u8, base[0..query_at], "/");
    var removed_suffix = false;
    for ([_][]const u8{ "/chat/completions", "/messages", "/api/chat" }) |suffix| if (std.mem.endsWith(u8, path, suffix)) {
        path = path[0 .. path.len - suffix.len];
        removed_suffix = true;
        break;
    };
    if (kind == .ollama) return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ path, if (std.mem.endsWith(u8, path, "/api")) "/tags" else "/api/tags", query });
    const uri = try std.Uri.parse(path);
    const uri_path = switch (uri.path) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
    const version = if (!removed_suffix and uri_path.len == 0) "/v1" else "";
    return std.fmt.allocPrint(allocator, "{s}{s}/models{s}", .{ path, version, query });
}

test "model catalog preserves toggle and longest unambiguous model prefix" {
    var c = try Catalog.parse(std.testing.allocator,
        \\{"xiaomi":{"models":{"mimo-v2.6-pro":{"reasoning":true,"reasoning_options":[{"type":"toggle"}],"limit":{"context":1048576}},"mimo-v2.6":{"reasoning":false}}}}
    , .models_dev);
    defer c.deinit();
    try std.testing.expect(c.resolve("xiaomi", "mimo-v2.6-pro-20261001").?.toggle);
    try std.testing.expect(c.resolve("my proxy", "xiaomi/mimo-v2.6-pro").?.toggle);
    try std.testing.expect(c.resolve("xiaomi", "mimo-v2.60") == null);
}
test "model catalog keeps protocol base path and rejects ambiguous fallback" {
    const a = std.testing.allocator;
    const url = try endpoint(a, "https://proxy.test/gateway/v1/chat/completions", .openai_compat);
    defer a.free(url);
    try std.testing.expectEqualStrings("https://proxy.test/gateway/v1/models", url);
    var c = try Catalog.parse(a,
        \\{"one":{"models":{"m":{"reasoning":true}}},"two":{"models":{"m":{"reasoning":false}}}}
    , .models_dev);
    defer c.deinit();
    try std.testing.expect(c.resolve("unknown", "m") == null);
    try std.testing.expect(c.resolve("one", "m").?.reasoning.?);
}

test "model catalog parses actual protocol metadata without inventing thinking levels" {
    const a = std.testing.allocator;
    const ollama = try std.json.parseFromSlice(std.json.Value, a, "{\"thinking\":{\"values\":[true,false],\"default\":false}}", .{});
    defer ollama.deinit();
    const c = metadata(ollama.value);
    try std.testing.expect(c.control_known and c.toggle and !c.thinking_default.?);
    const claude = try std.json.parseFromSlice(std.json.Value, a, "{\"capabilities\":{\"thinking\":{\"supported\":true,\"types\":{\"adaptive\":{\"supported\":true},\"disabled\":{\"supported\":true}}},\"effort\":{\"low\":{\"supported\":true},\"high\":{\"supported\":true}}}}", .{});
    defer claude.deinit();
    const d = metadata(claude.value);
    try std.testing.expect(d.adaptive and d.toggle and d.efforts[0] and d.efforts[2] and !d.efforts[1]);
}

test "model catalog uses provider-specific model endpoints and preserves custom base paths" {
    const a = std.testing.allocator;
    for ([_]struct { base: []const u8, kind: Kind, expected: []const u8 }{
        .{ .base = "https://api.anthropic.com", .kind = .anthropic, .expected = "https://api.anthropic.com/v1/models" },
        .{ .base = "https://proxy.test/custom/chat/completions?api-version=v1", .kind = .openai_compat, .expected = "https://proxy.test/custom/models?api-version=v1" },
        .{ .base = "http://localhost:11434/api/chat", .kind = .ollama, .expected = "http://localhost:11434/api/tags" },
    }) |item| {
        const url = try endpoint(a, item.base, item.kind);
        defer a.free(url);
        try std.testing.expectEqualStrings(item.expected, url);
    }
}

test "model catalog preserves gateway reasoning levels and real metadata" {
    var c = try Catalog.parse(std.testing.allocator,
        \\{"data":[{"id":"gateway/model-a","owned_by":"gateway","reasoning":true,"context_window":872000,"modalities":{"input":["text","image"]},"reasoning_levels":["low","high","ultra"]},{"id":"gateway/model-b","supported_reasoning_levels":[{"effort":"medium"},{"effort":"max"}]},{"id":"gateway/model-c","reasoning_levels":[]}]}
    , .endpoint);
    defer c.deinit();
    const first = c.resolve("gateway", "gateway/model-a").?;
    try std.testing.expect(first.reasoning.? and first.vision.?);
    try std.testing.expectEqual(@as(u32, 872000), first.context.?);
    try std.testing.expectEqual([7]bool{ true, false, true, false, false, false, true }, first.efforts);
    const second = c.resolve("gateway", "gateway/model-b").?;
    try std.testing.expectEqual([7]bool{ false, true, false, false, true, false, false }, second.efforts);
    const empty = c.resolve("gateway", "gateway/model-c").?;
    try std.testing.expect(empty.control_known and !empty.hasControl());
}

test "gateway none is a native effort and undeclared ultra stays unavailable" {
    var catalog = try Catalog.parse(std.testing.allocator, "{\"data\":[{\"id\":\"extended\",\"reasoning_levels\":[\"none\",\"ultra\"]},{\"id\":\"limited\",\"reasoning_levels\":[\"low\"]}]}", .endpoint);
    defer catalog.deinit();
    const extended = catalog.resolve("", "extended").?;
    try std.testing.expect(extended.efforts[5] and extended.efforts[6]);
    try std.testing.expect(!extended.toggle);
    const limited = catalog.resolve("", "limited").?;
    try std.testing.expect(!limited.efforts[5] and !limited.efforts[6]);
}
