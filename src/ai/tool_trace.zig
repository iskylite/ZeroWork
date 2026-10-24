//! Test-build instrumentation. Formal App builds never emit acceptance traces.
const std = @import("std");
pub fn emit(value: anytype) void {
    if (!@import("../platform/runtime_mode.zig").automation) return;
    const encoded = std.json.Stringify.valueAlloc(std.heap.c_allocator, value, .{}) catch return;
    defer std.heap.c_allocator.free(encoded);
    std.log.info("AI_TOOL_TRACE {s}", .{encoded});
}

pub const WireSummary = struct {
    names: [16][]const u8 = undefined,
    name_count: usize = 0,
    result_ids: [64][]const u8 = undefined,
    result_count: usize = 0,
    use_ids: [64][]const u8 = undefined,
    use_count: usize = 0,
    images: [16]ImageSummary = undefined,
    image_count: usize = 0,
    pub const ImageSummary = struct { mime: []const u8, bytes: usize, width: ?u32 = null, height: ?u32 = null, sha256: [64]u8 };
};
/// Borrow only IDs/names from actual serialized JSON. Both function tools and
/// native Anthropic tool_use/tool_result blocks are observed, without logging
/// credentials, attachment bytes, or the full provider body.
pub fn summarize(root: std.json.Value) WireSummary {
    var result: WireSummary = .{};
    if (root != .object) return result;
    if (root.object.get("tools")) |definitions| {
        if (definitions == .array) for (definitions.array.items) |definition| {
            if (result.name_count == result.names.len) break;
            if (definition != .object) continue;
            const object = if (definition.object.get("function")) |function| if (function == .object) function else continue else definition;
            const name = object.object.get("name") orelse continue;
            if (name != .string) continue;
            result.names[result.name_count] = name.string;
            result.name_count += 1;
        };
    }
    if (root.object.get("messages")) |messages| {
        if (messages == .array) for (messages.array.items) |message| {
            if (message != .object) continue;
            if (message.object.get("tool_call_id")) |id| if (id == .string and result.result_count < result.result_ids.len) {
                result.result_ids[result.result_count] = id.string;
                result.result_count += 1;
            };
            if (message.object.get("tool_calls")) |calls| if (calls == .array) for (calls.array.items) |call| {
                if (call != .object) continue;
                const id = call.object.get("id") orelse continue;
                if (id != .string or result.use_count == result.use_ids.len) continue;
                result.use_ids[result.use_count] = id.string;
                result.use_count += 1;
            };
            const content = message.object.get("content") orelse continue;
            if (content != .array) continue;
            for (content.array.items) |block| {
                if (block != .object) continue;
                const kind = block.object.get("type") orelse continue;
                if (kind != .string) continue;
                if (std.mem.eql(u8, kind.string, "tool_result")) {
                    const id = block.object.get("tool_use_id") orelse continue;
                    if (id != .string or result.result_count == result.result_ids.len) continue;
                    result.result_ids[result.result_count] = id.string;
                    result.result_count += 1;
                } else if (std.mem.eql(u8, kind.string, "tool_use")) {
                    const id = block.object.get("id") orelse continue;
                    if (id != .string or result.use_count == result.use_ids.len) continue;
                    result.use_ids[result.use_count] = id.string;
                    result.use_count += 1;
                }
            }
        };
    }
    collectImages(root, &result, 0);
    return result;
}
/// Inspect the serialized body rather than trusting a pre-serialization count.
pub fn wire(body: []const u8) void {
    if (!@import("../platform/runtime_mode.zig").automation) return;
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, body, .{}) catch return;
    defer parsed.deinit();
    const summary = summarize(parsed.value);
    emit(.{ .event = "wire_request", .tool_names = summary.names[0..summary.name_count], .tool_result_ids = summary.result_ids[0..summary.result_count], .tool_use_ids = summary.use_ids[0..summary.use_count], .body_bytes = body.len, .image_count = summary.image_count, .images = summary.images[0..summary.image_count] });
}

test "wire summary observes native Anthropic declarations uses and original result IDs" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"tools":[{"name":"run_command","input_schema":{"type":"object"}},{"name":"read_terminal"}],"messages":[{"role":"assistant","content":[{"type":"tool_use","id":"toolu_real","name":"run_command","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_real","content":"actual-output"}]}]}
    , .{});
    defer parsed.deinit();
    const summary = summarize(parsed.value);
    try std.testing.expectEqual(@as(usize, 2), summary.name_count);
    try std.testing.expectEqualStrings("run_command", summary.names[0]);
    try std.testing.expectEqualStrings("read_terminal", summary.names[1]);
    try std.testing.expectEqualStrings("toolu_real", summary.result_ids[0]);
    try std.testing.expectEqualStrings("toolu_real", summary.use_ids[0]);
}

fn collectImages(value: std.json.Value, out: *WireSummary, depth: usize) void {
    if (depth > 20 or out.image_count == out.images.len) return;
    if (value == .array) {
        for (value.array.items) |item| collectImages(item, out, depth + 1);
        return;
    }
    if (value != .object) return;
    if (value.object.get("image_url")) |url_object| if (url_object == .object) if (url_object.object.get("url")) |url| if (url == .string and std.mem.startsWith(u8, url.string, "data:image/")) {
        const separator = std.mem.indexOf(u8, url.string, ";base64,") orelse return;
        summarizeImage(url.string[5..separator], url.string[separator + 8 ..], out);
    };
    if (value.object.get("source")) |source| if (source == .object) {
        const mime = source.object.get("media_type");
        const data = source.object.get("data");
        if (mime != null and data != null and mime.? == .string and data.? == .string) summarizeImage(mime.?.string, data.?.string, out);
    };
    if (value.object.get("images")) |encoded| if (encoded == .array) for (encoded.array.items) |data| if (data == .string) summarizeImage("image/unknown", data.string, out);
    var iterator = value.object.iterator();
    while (iterator.next()) |field| collectImages(field.value_ptr.*, out, depth + 1);
}
fn summarizeImage(mime: []const u8, encoded: []const u8, out: *WireSummary) void {
    if (out.image_count == out.images.len or encoded.len > 14 * 1024 * 1024) return;
    const decoder = std.base64.standard.Decoder;
    const length = decoder.calcSizeForSlice(encoded) catch return;
    const bytes = std.heap.c_allocator.alloc(u8, length) catch return;
    defer std.heap.c_allocator.free(bytes);
    decoder.decode(bytes, encoded) catch return;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var summary: WireSummary.ImageSummary = .{ .mime = mime, .bytes = bytes.len, .sha256 = std.fmt.bytesToHex(digest, .lower) };
    if (bytes.len >= 24 and std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) {
        summary.width = std.mem.readInt(u32, bytes[16..20], .big);
        summary.height = std.mem.readInt(u32, bytes[20..24], .big);
        summary.mime = "image/png";
    }
    out.images[out.image_count] = summary;
    out.image_count += 1;
}
