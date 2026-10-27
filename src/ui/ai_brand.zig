//! Local brand marks shared by provider settings and assistant model choices.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub const Brand = enum { openai, anthropic, ollama, grok, gemini, deepseek, qwen, kimi, mistral, meta, zhipu, minimax, moonshot };
pub fn basename(id: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, id, '/')) |i| id[i + 1 ..] else id;
}
fn prefix(text: []const u8, value: []const u8) bool {
    return text.len >= value.len and std.ascii.eqlIgnoreCase(text[0..value.len], value);
}
pub fn model(id: []const u8) ?Brand {
    const name = basename(id);
    const aliases = .{ .{ "chatgpt", Brand.openai }, .{ "gpt", Brand.openai }, .{ "o1", Brand.openai }, .{ "o3", Brand.openai }, .{ "o4", Brand.openai }, .{ "claude", Brand.anthropic }, .{ "grok", Brand.grok }, .{ "gemini", Brand.gemini }, .{ "gemma", Brand.gemini }, .{ "deepseek", Brand.deepseek }, .{ "qwen", Brand.qwen }, .{ "qwq", Brand.qwen }, .{ "kimi", Brand.kimi }, .{ "moonshot", Brand.moonshot }, .{ "mistral", Brand.mistral }, .{ "mixtral", Brand.mistral }, .{ "codestral", Brand.mistral }, .{ "llama", Brand.meta }, .{ "glm", Brand.zhipu }, .{ "minimax", Brand.minimax } };
    inline for (aliases) |pair| if (prefix(name, pair[0])) return pair[1];
    return null;
}
pub fn provider(name: []const u8, endpoint: []const u8) ?Brand {
    if (std.ascii.eqlIgnoreCase(name, "xAI")) return .grok;
    if (std.ascii.eqlIgnoreCase(name, "Google")) return .gemini;
    if (std.ascii.eqlIgnoreCase(name, "Claude")) return .anthropic;
    inline for (@typeInfo(Brand).@"enum".field_names) |field| {
        if (std.ascii.eqlIgnoreCase(name, field)) return @field(Brand, field);
    }
    // The protocol alone does not identify a custom gateway's brand.
    const host_start = if (std.mem.indexOf(u8, endpoint, "://")) |i| i + 3 else return null;
    const host = endpoint[host_start .. host_start + (std.mem.indexOfAny(u8, endpoint[host_start..], "/:?#") orelse endpoint.len - host_start)];
    const domains = .{ .{ "openai.com", Brand.openai }, .{ "anthropic.com", Brand.anthropic }, .{ "x.ai", Brand.grok }, .{ "googleapis.com", Brand.gemini }, .{ "deepseek.com", Brand.deepseek }, .{ "moonshot.cn", Brand.moonshot }, .{ "moonshot.ai", Brand.moonshot }, .{ "minimax.io", Brand.minimax }, .{ "minimaxi.com", Brand.minimax }, .{ "bigmodel.cn", Brand.zhipu } };
    inline for (domains) |pair| {
        if (std.ascii.eqlIgnoreCase(host, pair[0]) or (host.len > pair[0].len and host[host.len - pair[0].len - 1] == '.' and std.ascii.eqlIgnoreCase(host[host.len - pair[0].len ..], pair[0]))) return pair[1];
    }
    return null;
}
pub fn initial(name: []const u8, buffer: *[4]u8) []const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return "?";
    const len = std.unicode.utf8ByteSequenceLength(trimmed[0]) catch return "?";
    if (len > trimmed.len or !std.unicode.utf8ValidateSlice(trimmed[0..len])) return "?";
    @memcpy(buffer[0..len], trimmed[0..len]);
    if (len == 1) buffer[0] = std.ascii.toUpper(buffer[0]);
    return buffer[0..len];
}
fn asset(brand: Brand) ui.SvgAsset {
    return switch (brand) {
        inline else => |value| @field(@import("ai_brand_assets.zig"), @tagName(value)),
    };
}
pub fn mount(cx: *ui.Cx, brand: ?Brand, name: []const u8, size: f32) !*ui.Node {
    const c = theme.current();
    const root = try ui.box(cx, .{ .width = .{ .px = size }, .height = .{ .px = size }, .align_items = .center, .justify = .center, .background = c.hover, .border = .{ .radius = @min(8, size / 4) }, .flex_shrink = 0 }, .{});
    var buffer: [4]u8 = undefined;
    const text = initial(name, &buffer);
    const child = if (brand) |value| try ui.iconTint(cx, asset(value), c.fg_1, .{ .width = .{ .px = size * 2 / 3 }, .height = .{ .px = size * 2 / 3 } }) else try ui.text(cx, text, .{ .font_size = size * 0.43, .font_weight = 600, .color = c.fg_2 });
    try root.appendChild(cx.allocator, child);
    return root;
}

test "brand uses last slash segment and case insensitive model prefixes" {
    try std.testing.expectEqual(Brand.grok, model("gateway/grok/grok-4.7").?);
    try std.testing.expectEqual(Brand.anthropic, model("team/CLAUDE-sonnet-4-5").?);
    try std.testing.expectEqual(Brand.openai, model("gpt-5-custom").?);
    try std.testing.expectEqual(@as(?Brand, null), model("grok/custom-model"));
    try std.testing.expectEqual(@as(?Brand, null), model("my-gpt"));
    try std.testing.expectEqual(@as(?Brand, null), provider("Magpie", "http://127.0.0.1:3425/v1"));
    try std.testing.expectEqual(Brand.openai, provider("Team", "https://api.openai.com/v1").?);
    try std.testing.expectEqual(@as(?Brand, null), provider("Team", "https://openai.com.example.org/v1"));
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqualStrings("团", initial("团队服务", &buffer));
    try std.testing.expectEqualStrings("M", initial("magpie", &buffer));
}

test "every bundled brand mark has drawable native geometry" {
    inline for (@typeInfo(Brand).@"enum".field_names) |name| {
        const value = asset(@field(Brand, name));
        const rep = value.pickRep(20).?;
        try std.testing.expect(rep.shapes.len > 0);
        for (rep.shapes) |shape| try std.testing.expect(shape.contours.len > 0);
    }
}
