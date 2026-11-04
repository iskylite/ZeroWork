//! Budget-triggered image offload. Only active occurrences enter the provider
//! request; immutable originals remain conversation-owned and can be reread.
//! Like DSH image offload, decisions are monotonic and select oldest first.
const std = @import("std");
const p = @import("provider.zig");
const images = @import("image_attachments.zig");
const identity = @import("../host/identity.zig");
const registry = @import("registry.zig");

pub const tool_id = "image.read";
pub const reference_prefix = "image:sha256:";
pub const reference_length = reference_prefix.len + 64;

/// Advertise recovery before allowing local-budget offload. Other providers'
/// image workflows keep their existing behavior until they contribute a reader.
pub fn enabled(request: p.ChatRequest) bool {
    for (request.tools) |tool| if (tool.dynamic) |definition| {
        if (std.mem.eql(u8, definition.id, tool_id)) return true;
    };
    return false;
}

pub fn reference(a: std.mem.Allocator, image: images.ContentRef) ![]const u8 {
    const content = image.content() orelse return error.EmptyAttachmentResult;
    return std.fmt.allocPrint(a, reference_prefix ++ "{s}", .{std.fmt.bytesToHex(content.sha256, .lower)});
}

pub fn validateReference(value: []const u8) !void {
    if (value.len != reference_length or !std.mem.startsWith(u8, value, reference_prefix)) return error.InvalidImageReference;
    for (value[reference_prefix.len..]) |byte| if (!(byte >= '0' and byte <= '9') and !(byte >= 'a' and byte <= 'f')) return error.InvalidImageReference;
}

fn matches(image: images.ContentRef, value: []const u8) bool {
    const content = image.content() orelse return false;
    const hex = std.fmt.bytesToHex(content.sha256, .lower);
    return std.mem.eql(u8, &hex, value[reference_prefix.len..]);
}

/// No filesystem access: only snapshots in the exact captured conversation.
/// KVM snapshots additionally retain their original session generation.
pub fn find(messages: []const p.Message, value: []const u8, owner: identity.SessionHandle) !images.ContentRef {
    try validateReference(value);
    for (messages) |message| {
        if (message.image_owner == null or message.image_owner.?.eql(owner)) {
            for (message.images) |image| if (matches(image, value)) return image;
        }
        for (message.offloaded_images) |image| {
            if (image.owner != null and !image.owner.?.eql(owner)) continue;
            if (matches(image.reference, value)) return image.reference;
        }
    }
    return error.ImageReferenceNotFound;
}

fn sameSource(left: p.Message, right: p.Message) bool {
    if (left.image_transform != right.image_transform) return false;
    if (left.image_owner) |owner| return if (right.image_owner) |other| owner.eql(other) else false;
    return right.image_owner == null;
}

fn samePixels(left: images.ContentRef, right: images.ContentRef) bool {
    const a = left.content() orelse return false;
    const b = right.content() orelse return false;
    return a.width == b.width and a.height == b.height and std.mem.eql(u8, &a.pixel_sha256, &b.pixel_sha256);
}

fn archive(a: std.mem.Allocator, message: *p.Message, index: usize, reason: []const u8) !void {
    const image = message.images[index];
    const ref = try reference(a, image);
    const note = try std.fmt.allocPrint(a, "\n[Image {s}: {s}. Original retained; " ++
        "use image.read with image_ref and the authorized session_ids to view it again. " ++
        "This reference contains no pixels and is not a new/current screen observation.]", .{ reason, ref });
    const text = try std.mem.concat(a, u8, &.{ message.content, note });
    const archived = try a.alloc(p.OffloadedImage, message.offloaded_images.len + 1);
    @memcpy(archived[0..message.offloaded_images.len], message.offloaded_images);
    archived[message.offloaded_images.len] = .{ .reference = image, .owner = message.image_owner };
    const active = try a.alloc(images.ContentRef, message.images.len - 1);
    @memcpy(active[0..index], message.images[0..index]);
    @memcpy(active[index..], message.images[index + 1 ..]);
    message.content = text;
    message.offloaded_images = archived;
    message.images = active;
}

/// Keep the latest occurrence's pixels, retaining every earlier observation
/// and its original evidence. Scope and coordinate mappings must both match.
pub fn deduplicate(a: std.mem.Allocator, messages: []p.Message) !usize {
    var removed: usize = 0;
    for (messages, 0..) |*message, mi| {
        var ii: usize = 0;
        while (ii < message.images.len) {
            const duplicate = found: {
                for (messages[mi..], 0..) |later, offset| {
                    if (!sameSource(message.*, later)) continue;
                    const start = if (offset == 0) ii + 1 else 0;
                    for (later.images[start..]) |image| if (samePixels(message.images[ii], image)) break :found true;
                }
                break :found false;
            };
            if (duplicate) {
                try archive(a, message, ii, "reuses identical pixels in a later observation in this request");
                removed += 1;
            } else ii += 1;
        }
    }
    return removed;
}

/// Images in the latest user input or latest tool batch have not yet reached
/// the model. Budget admission must fail/compact instead of hiding them.
fn protectedStart(messages: []const p.Message) usize {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        if (messages[i].role == .assistant) return i + 1;
        if (messages[i].role == .user) return i;
    }
    return messages.len;
}

/// Allocation belongs to the caller's request arena. References are moved,
/// never released or retained here: the owning Message keeps the same refs.
/// Budget failure is observed before the oldest occurrence is omitted. No
/// latest-image rule, no eviction under budget, no side-effect/tool replay.
pub fn apply(a: std.mem.Allocator, messages: []p.Message, input: p.ChatRequest, window: u32, kind: registry.Kind) !usize {
    var request = input;
    request.messages = messages;
    var omitted = try deduplicate(a, messages);
    const protected = protectedStart(messages);
    while (try exceedsBudget(request, window, kind)) {
        const index = for (messages, 0..) |message, i| {
            if (i < protected and message.images.len != 0) break i;
        } else break; // Text-only overflow belongs to ordinary compaction.
        const message = &messages[index];
        try archive(a, message, 0, "offloaded after request budget overflow");
        omitted += 1;
    }
    if (try exceedsBudget(request, window, kind)) {
        var pending = request;
        pending.messages = messages[protected..];
        if (activeCount(pending.messages) > 0 and try exceedsBudget(pending, window, kind)) return error.ContextBudgetExceeded;
    }
    return omitted;
}

fn exceedsBudget(request: p.ChatRequest, window: u32, kind: registry.Kind) !bool {
    const budget = @import("local_text_request.zig");
    for (request.messages) |message| {
        if ((message.role == .user or message.role == .tool) and message.images.len > images.max_count) return true;
    }
    budget.checkContext(request, window) catch |err| switch (err) {
        error.ContextBudgetExceeded => return true,
        else => return err,
    };
    _ = @import("provider_http.zig").requestBodySize(kind, request, window) catch |err| switch (err) {
        error.RequestTooLarge, error.ToolRequestTooLarge => return true,
        else => return err,
    };
    return false;
}

/// Preserve access to offloaded evidence when text compaction replaces a
/// prefix. Active prefix images were read by the summary and also stay local.
pub fn retainCompacted(a: std.mem.Allocator, prefix: []const p.Message, memory: *p.Message) !void {
    var refs: std.ArrayList(p.OffloadedImage) = .empty;
    for (prefix) |message| {
        try refs.appendSlice(a, message.offloaded_images);
        for (message.images) |image| try refs.append(a, .{ .reference = image, .owner = message.image_owner });
    }
    memory.offloaded_images = try refs.toOwnedSlice(a);
    // Keep references discoverable even when the model's summary omitted IDs.
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, memory.content);
    for (memory.offloaded_images) |image| {
        try text.appendSlice(a, "\nRetained image reference: ");
        try text.appendSlice(a, try reference(a, image.reference));
    }
    memory.content = try text.toOwnedSlice(a);
}

pub fn readResult(a: std.mem.Allocator, invocation: @import("plugin_tools.zig").Invocation, image: ?images.ContentRef) !@import("plugin_tools.zig").ToolResult {
    const api = @import("plugin_tools.zig");
    const ref = invocation.arguments.object.get("image_ref").?.string;
    const available = if (image) |value| value.content() != null else false;
    const text = try std.json.Stringify.valueAlloc(a, .{
        .image_ref = ref,
        .historical_image = true,
        .new_observation = false,
        .error_code = if (!available) @as(?[]const u8, "ImageReferenceNotFound") else null,
        .meaning = "Saved pixels only; this read neither captures the current screen nor refreshes input authority.",
    }, .{ .emit_null_optional_fields = false });
    errdefer a.free(text);
    const blocks = try a.alloc(api.ContentBlock, if (available) 2 else 1);
    blocks[0] = .{ .structured = text };
    if (available) blocks[1] = .{ .image_ref = image.?.retain() };
    return .{ .status = if (available) .succeeded else .failed, .blocks = blocks, .receipt = .{ .owner = invocation.owner, .operation_id = invocation.operation_id } };
}

const test_png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
    "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++
    "\x00\x00\x00\x00IEND\xae\x42\x60\x82";

fn testRequest(messages: []const p.Message) p.ChatRequest {
    return .{ .model = "grok-4.7@500k", .system = "", .messages = messages, .vision = true, .tool_images = true, .max_output = 4096 };
}

fn activeCount(messages: []const p.Message) usize {
    var count: usize = 0;
    for (messages) |message| count += message.images.len;
    return count;
}

test "image offload efficiency identical observations serialize once with all evidence retained" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var image = try images.ContentRef.create(a, "fixture", test_png, 1, .{});
    defer image.release();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(171), .generation = 3 };
    var messages: [10]p.Message = undefined;
    for (&messages) |*message| message.* = .{ .content = "fresh observation; identical pixels", .images = &.{image}, .image_owner = owner };
    try std.testing.expectEqual(@as(usize, 9), try apply(arena.allocator(), &messages, testRequest(&messages), 500_000, .openai_compat));
    try std.testing.expectEqual(@as(usize, 1), activeCount(&messages));
    try std.testing.expectEqual(@as(usize, 1), messages[9].images.len);
    for (messages[0..9]) |message| try std.testing.expectEqual(@as(usize, 1), message.offloaded_images.len);
    for ([_]registry.Kind{ .openai_compat, .anthropic, .ollama }) |kind| {
        const body = try @import("provider_http.zig").requestBody(a, kind, testRequest(&messages), 500_000);
        defer a.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), @import("tool_trace.zig").summarize(parsed.value).image_count);
    }
    var history = try @import("wire_history.zig").History.copy(a, &messages, "");
    defer history.deinit();
    try std.testing.expectEqual(@as(usize, 0), try apply(arena.allocator(), &messages, testRequest(&messages), 500_000, .openai_compat));
}

test "image offload efficiency preserves new pixels and separates owners and transforms" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var image = try images.ContentRef.create(a, "fixture", test_png, 1, .{});
    defer image.release();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(171), .generation = 3 };
    var messages = [_]p.Message{
        .{ .content = "one", .images = &.{image}, .image_owner = owner },
        .{ .content = "different mapping", .images = &.{image}, .image_owner = owner, .image_transform = 1 },
        .{ .content = "different generation", .images = &.{image}, .image_owner = .{ .session_id = owner.session_id, .generation = 4 } },
    };
    try std.testing.expectEqual(@as(usize, 0), try deduplicate(arena.allocator(), &messages));
    var fresh = [_]p.Message{.{ .content = "new screen", .images = &.{image}, .image_owner = owner }};
    try std.testing.expectError(error.ContextBudgetExceeded, apply(arena.allocator(), &fresh, testRequest(&fresh), 8192, .openai_compat));
    try std.testing.expectEqual(@as(usize, 1), activeCount(&fresh));
    try std.testing.expectError(error.ContextBudgetExceeded, @import("local_text_request.zig").checkContext(testRequest(&fresh), 8192));
}

test "image offload keeps multiple images below budget and evicts only oldest on overflow" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var image = try images.ContentRef.create(a, "fixture", test_png, 1, .{});
    defer image.release();
    var messages = [_]p.Message{
        .{ .content = "first", .images = &.{image}, .image_transform = 1 },
        .{ .content = "second", .images = &.{image}, .image_transform = 2 },
        .{ .content = "third", .images = &.{image}, .image_transform = 3 },
        .{ .content = "fourth", .images = &.{image}, .image_transform = 4 },
    };
    try std.testing.expectEqual(@as(usize, 0), try apply(aa, messages[0..3], testRequest(messages[0..3]), 500_000, .openai_compat));
    try std.testing.expectEqual(@as(usize, 3), activeCount(messages[0..3]));
    try std.testing.expectEqual(@as(usize, 1), try apply(aa, &messages, testRequest(&messages), 500_000, .openai_compat));
    try std.testing.expectEqual(@as(usize, 3), activeCount(&messages));
    try std.testing.expectEqual(@as(usize, 1), messages[0].offloaded_images.len);
    try std.testing.expect(std.mem.startsWith(u8, messages[0].content, "first\n[Image offloaded"));
    try std.testing.expectEqualStrings("second", messages[1].content);
    // Retry and route/model budget growth cannot automatically restore old occurrences.
    try std.testing.expectEqual(@as(usize, 0), try apply(aa, &messages, testRequest(&messages), 500_000, .openai_compat));
    try std.testing.expectEqual(@as(usize, 0), try apply(aa, &messages, testRequest(&messages), 1_000_000, .openai_compat));
    try std.testing.expectEqual(@as(usize, 3), activeCount(&messages));
    for ([_]registry.Kind{ .openai_compat, .anthropic, .ollama }) |kind| {
        const body = try @import("provider_http.zig").requestBody(a, kind, testRequest(&messages), 500_000);
        defer a.free(body);
        const json = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer json.deinit();
        const wire = @import("tool_trace.zig").summarize(json.value);
        try std.testing.expectEqual(@as(usize, 3), wire.image_count);
    }
}

test "image offload ten observations retain three under 500k and preserve original evidence" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var image = try images.ContentRef.create(a, "fixture", test_png, 1, .{});
    defer image.release();
    var messages: [10]p.Message = undefined;
    var total: usize = 0;
    for (&messages, 0..) |*message, i| {
        message.* = .{ .content = "observation", .images = &.{image}, .image_transform = i + 1 };
        total += try apply(arena.allocator(), messages[0 .. i + 1], testRequest(messages[0 .. i + 1]), 500_000, .openai_compat);
    }
    try std.testing.expectEqual(@as(usize, 7), total);
    try std.testing.expectEqual(@as(usize, 3), activeCount(&messages));
    var history = try @import("wire_history.zig").History.copy(a, &messages, "answer");
    defer history.deinit();
    image.release();
    for (history.messages[0..7]) |message| {
        try std.testing.expectEqual(@as(usize, 1), message.offloaded_images.len);
        try std.testing.expectEqualSlices(u8, test_png, message.offloaded_images[0].reference.content().?.bytes);
    }
    try std.testing.expect(try @import("local_text_request.zig").inputTokens(testRequest(history.messages)) < 500_000);
}

test "image offload reread is scoped immutable and creates a new active occurrence" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(171), .generation = 3 };
    var image = try images.ContentRef.create(a, "fixture", test_png, 1, .{});
    defer image.release();
    const ref = try reference(aa, image);
    var messages = [_]p.Message{ .{ .content = "screen", .images = &.{image}, .image_owner = owner }, .{ .role = .assistant, .content = "screen read" } };
    // A small context forces even the only image out: policy is budget-based.
    try std.testing.expectEqual(@as(usize, 1), try apply(aa, &messages, testRequest(&messages), 8192, .openai_compat));
    const saved = try find(&messages, ref, owner);
    try std.testing.expectError(error.ImageReferenceNotFound, find(&messages, ref, .{ .session_id = owner.session_id, .generation = 4 }));
    try std.testing.expectError(error.ImageReferenceNotFound, find(&.{}, ref, owner));
    try std.testing.expectError(error.InvalidImageReference, find(&messages, "/tmp/unrelated.png", owner));
    const args = try std.json.parseFromSlice(std.json.Value, aa, try std.fmt.allocPrint(aa, "{{\"session_ids\":[171],\"image_ref\":\"{s}\"}}", .{ref}), .{});
    var result = try readResult(a, .{ .owner = owner, .operation_id = 9, .tool_id = tool_id, .effect = .observe_image, .arguments = args.value, .arguments_json = "", .arguments_hash = @splat(0) }, saved);
    defer result.deinit(a);
    try std.testing.expectEqual(@import("plugin_tools.zig").Status.succeeded, result.status);
    try std.testing.expectEqualSlices(u8, test_png, result.blocks[1].image_ref.content().?.bytes);
    try std.testing.expect(std.mem.indexOf(u8, result.blocks[0].structured, "\"new_observation\":false") != null);
    // A reread gets its own message; it never unmasks the original occurrence.
    var next = [_]p.Message{ messages[0], .{ .content = "saved pixels", .images = &.{saved}, .image_owner = owner } };
    try std.testing.expectEqual(@as(usize, 0), try apply(aa, &next, testRequest(&next), 500_000, .openai_compat));
    try std.testing.expectEqual(@as(usize, 0), next[0].images.len);
    try std.testing.expectEqual(@as(usize, 1), next[1].images.len);
}

test "image offload compaction and history copies retain references after source release" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var image = try images.ContentRef.create(a, "fixture", test_png, 1, .{});
    defer image.release();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(171), .generation = 3 };
    var source = [_]p.Message{ .{ .content = "evidence", .images = &.{image}, .image_owner = owner }, .{ .role = .assistant, .content = "evidence read" } };
    _ = try apply(arena.allocator(), &source, testRequest(&source), 8192, .openai_compat);
    var memory: p.Message = .{ .content = "summary" };
    try retainCompacted(arena.allocator(), &source, &memory);
    var first = try @import("wire_history.zig").History.copy(a, &.{memory}, "");
    defer first.deinit();
    var second = try @import("wire_history.zig").History.copy(a, first.messages, "");
    defer second.deinit();
    first.deinit();
    image.release();
    const ref = try reference(arena.allocator(), second.messages[0].offloaded_images[0].reference);
    try std.testing.expect(std.mem.indexOf(u8, second.messages[0].content, ref) != null);
    const restored = try find(second.messages, ref, owner);
    try std.testing.expectEqualSlices(u8, test_png, restored.content().?.bytes);
    try std.testing.expectEqual(@as(usize, 0), try @import("image_budget.zig").validate(testRequest(second.messages)));
}

test "image offload does not treat text overflow as successful image recovery" {
    var messages = [_]p.Message{.{ .content = "a large text request" }};
    try std.testing.expectEqual(@as(usize, 0), try apply(std.testing.allocator, &messages, testRequest(&messages), 1, .openai_compat));
    try std.testing.expectError(error.ContextBudgetExceeded, @import("local_text_request.zig").checkContext(testRequest(&messages), 1));
}

test "image offload loop persists omission across failed answer retry and new turns" {
    const a = std.testing.allocator;
    const loop_mod = @import("tool_loop.zig");
    const scope: @import("tool_scope.zig").Scope = .{ .owner = .{ .session = 171 }, .members = .{ .ids = .{171} ++ @as([15]u64, @splat(0)), .len = 1 } };
    var image = try images.ContentRef.create(a, "fixture", test_png, 1, .{});
    defer image.release();
    const messages = [_]p.Message{
        .{ .content = "a", .images = &.{image}, .image_transform = 1 }, .{ .content = "b", .images = &.{image}, .image_transform = 2 },
        .{ .content = "c", .images = &.{image}, .image_transform = 3 }, .{ .content = "d", .images = &.{image}, .image_transform = 4 },
    };
    const definition: p.ToolDefinition = .{ .session_ids = &.{171}, .dynamic = .{
        .id = tool_id,
        .name = "image__read",
        .description = "Read retained image",
        .schema = @import("../plugins/bmc_ikvm/tools.zig").read_image_schema,
    } };
    var request = testRequest(&messages);
    request.tools = &.{definition};
    var first = loop_mod.Loop.init(a, scope, 1, .{ .context_window = 500_000 });
    defer first.deinit();
    try first.start(request);
    try std.testing.expectEqual(@as(usize, 3), activeCount((try first.nextRequest()).messages));
    // A manual answer retry reuses the transcript without replaying any tool.
    try first.checkRequestBudget();
    try std.testing.expectEqual(@as(usize, 1), first.messages.items[0].offloaded_images.len);
    var history = try @import("wire_history.zig").History.copy(a, first.messages.items, "");
    defer history.deinit();
    request.messages = history.messages;
    var second = loop_mod.Loop.init(a, scope, 2, .{ .context_window = 1_000_000 });
    defer second.deinit();
    try second.start(request);
    const next = try second.nextRequest();
    try std.testing.expectEqual(@as(usize, 3), activeCount(next.messages));
    try std.testing.expectEqual(@as(usize, 1), next.messages[0].offloaded_images.len);
    try std.testing.expectEqual(@as(usize, 0), second.records.items.len);
}

test "image offload history allocation failures release active and archived references" {
    const a = std.testing.allocator;
    var image = try images.ContentRef.create(a, "fixture", test_png, 1, .{});
    defer image.release();
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator, original: images.ContentRef) !void {
            var history = try @import("wire_history.zig").History.copy(allocator, &.{.{
                .content = "image evidence",
                .images = &.{original},
                .offloaded_images = &.{.{ .reference = original }},
            }}, "answer");
            defer history.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(a, Scenario.run, .{image});
    try std.testing.expectEqualSlices(u8, test_png, image.content().?.bytes);
}

test "image offload also repairs transport overflow while token context still fits" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const raster = @import("../plugins/bmc_ikvm/observation_image.zig");
    const pixels = try a.alloc(u8, 1920 * 1200 * 4);
    defer a.free(pixels);
    var random = std.Random.DefaultPrng.init(719);
    random.random().bytes(pixels);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(171), .generation = 3 };
    const frame: @import("../plugins/bmc_ikvm/framebuffer.zig").Snapshot = .{ .session_handle = owner, .frame_generation = 1, .sequence = 1, .width = 1920, .height = 1200, .stride = 1920 * 4, .pixels = pixels, .received_monotonic_ns = 1 };
    var image = try raster.capture(a, frame, try raster.transform(1920, 1200, null, 1920, 1200), 1);
    defer image.release();
    var messages: [16]p.Message = undefined;
    for (&messages, 1..) |*message, i| message.* = .{ .content = "screen", .images = &.{image}, .image_owner = owner, .image_transform = i };
    var request = testRequest(&messages);
    request.model = "gpt-4o";
    try @import("local_text_request.zig").checkContext(request, 500_000);
    try std.testing.expectError(error.RequestTooLarge, @import("provider_http.zig").requestBodySize(.openai_compat, request, 500_000));
    const omitted = try apply(arena.allocator(), &messages, request, 500_000, .openai_compat);
    try std.testing.expect(omitted > 0 and omitted < messages.len - 1);
    try std.testing.expectEqual(messages.len - omitted, activeCount(&messages));
    try std.testing.expect(try @import("provider_http.zig").requestBodySize(.openai_compat, request, 500_000) <= @import("provider_http.zig").max_request_bytes);
}

test "efficiency bounded image reservation applies only within measured dimensions" {
    const a = std.testing.allocator;
    var image = try images.ContentRef.create(a, "fixture", test_png, 1, .{});
    defer image.release();
    const messages = [_]p.Message{.{ .content = "synthetic", .images = &.{image} }};
    var request = testRequest(&messages);
    request.image_token_reservation = 8192;
    request.image_token_max_width = 1920;
    request.image_token_max_height = 1200;
    try std.testing.expectEqual(@as(usize, 8192), try @import("image_budget.zig").validate(request));
    const snapshot = image.snapshot.?;
    const original_width = snapshot.value.width;
    snapshot.value.width = 1921;
    defer snapshot.value.width = original_width;
    try std.testing.expectEqual(@as(usize, 131072), try @import("image_budget.zig").validate(request));
}
