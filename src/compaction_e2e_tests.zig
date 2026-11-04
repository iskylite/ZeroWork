//! Run through e2e/ai_context_compaction.py, which owns the loopback model.
const std = @import("std");
const c = @import("ai/context_compaction.zig");
const p = @import("ai/provider.zig");
const History = @import("ai/wire_history.zig").History;
const a = std.testing.allocator;
fn config(path: []const u8) @import("ai/provider_config.zig").ProviderConfig {
    return .{ .kind = .openai_compat, .endpoint = path, .model = "compaction-fixture", .auth = .none, .context_window = 32768 };
}
fn history() !History {
    return History.copy(a, &.{ .{ .content = "Goal: implement backup. Constraint: no deployment. " ++ (comptime blk: {
        var text: []const u8 = "";
        for (0..100) |_| {
            text = text ++ "OLD_RAW_CONTEXT ";
        }
        break :blk text;
    }) }, .{ .role = .assistant, .content = "Observed: backup tests passed. Pending: review." }, .{ .content = "RECENT_FIRST" }, .{ .role = .assistant, .content = "Recent first answer" }, .{ .content = "RECENT_LAST" }, .{ .role = .assistant, .content = "Recent last answer" } }, "");
}
const id: c.Identity = .{ .owner = .{ .session = 101 }, .conversation = 1, .revision = 1 };
fn awaitResult(service: *c.Service, h: *History, identity: ?c.Identity, busy: bool) !void {
    for (0..5000) |_| {
        _ = service.poll(a, identity, h, busy);
        if (service.job == null) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
    return error.CompactionTestTimeout;
}
fn sink(_: *anyopaque, _: p.Delta) void {}
test "compaction real HTTP publishes memory and next model request contains only memory plus recent turns" {
    var h = try history();
    defer h.deinit();
    // Display history is a separate owned transcript, as in AiHost.
    var visible = try History.copy(a, h.messages, "");
    defer visible.deinit();
    const visible_hash = c.fingerprint(visible.messages);
    var service: c.Service = .{};
    defer service.deinit();
    try service.start(config("http://127.0.0.1:18987/success"), id, &h);
    try awaitResult(&service, &h, id, false);
    try std.testing.expectEqual(c.Status.succeeded, service.status);
    try std.testing.expectEqual(@as(usize, 5), h.messages.len);
    try std.testing.expect(std.mem.indexOf(u8, h.messages[0].content, "MEMORY_BACKUP_TESTS_PASSED") != null);
    try std.testing.expectEqualStrings("RECENT_FIRST", h.messages[1].content);
    try std.testing.expectEqual(visible_hash, c.fingerprint(visible.messages));
    var io: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer io.deinit();
    var context: @import("ai/provider_transport.zig").NativeContext = .{ .io = io.io() };
    var client = @import("ai/provider_client.zig").Client.native(a, &context, .openai_compat);
    var next: std.ArrayList(p.Message) = .empty;
    defer next.deinit(a);
    try next.appendSlice(a, h.messages);
    try next.append(a, .{ .content = "NEXT_REAL_REQUEST" });
    try client.chat(config("http://127.0.0.1:18987/next"), .{ .model = "compaction-fixture", .system = "Real assistant system", .messages = next.items }, sink, undefined);
}
test "compaction real HTTP failure cancellation stale owner conversation generation and transcript preserve history" {
    const scenarios = [_][]const u8{ "failure", "cancel", "owner", "conversation", "revision", "generation", "transcript", "busy", "empty", "acknowledgement", "larger", "budget" };
    for (scenarios) |scenario| {
        var h = try history();
        defer h.deinit();
        var service: c.Service = .{};
        defer service.deinit();
        var current: c.Identity = id;
        const endpoint = try std.fmt.allocPrint(a, "http://127.0.0.1:18987/{s}", .{scenario});
        defer a.free(endpoint);
        try service.startReserved(config(endpoint), id, &h, if (std.mem.eql(u8, scenario, "budget")) 32768 else 0);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
        if (std.mem.eql(u8, scenario, "cancel")) service.cancel();
        if (std.mem.eql(u8, scenario, "owner")) current.owner = .{ .session = 202 };
        if (std.mem.eql(u8, scenario, "conversation")) current.conversation = 2;
        if (std.mem.eql(u8, scenario, "revision")) current.revision = 2;
        if (std.mem.eql(u8, scenario, "generation")) current.scope_generation = 2;
        if (std.mem.eql(u8, scenario, "transcript")) {
            var replacement = try History.copy(a, &.{.{ .content = "NEW_CONTEXT_MUST_SURVIVE" }}, "");
            std.mem.swap(History, &h, &replacement);
            replacement.deinit();
        }
        const original = c.fingerprint(h.messages);
        try awaitResult(&service, &h, current, std.mem.eql(u8, scenario, "busy"));
        try std.testing.expectEqual(original, c.fingerprint(h.messages));
        try std.testing.expect(service.status == .failed or service.status == .cancelled);
    }
}

test "compaction real HTTP retains actual recent images and summarizes original old image pixels with vision model" {
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++ "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++ "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++ "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
    var image = try @import("ai/image_attachments.zig").ContentRef.create(a, "old-observation.png", png, 0, .{});
    defer image.release();
    var old = try history();
    defer old.deinit();
    var source = [_]p.Message{ old.messages[0], .{ .role = .assistant, .content = "", .tool_calls = &.{.{ .id = "old-image-call", .name = "synthetic__observe", .arguments = "{}" }} }, .{ .role = .tool, .content = "observed red pixel", .tool_call_id = "old-image-call", .images = &.{image} }, old.messages[2], old.messages[3], old.messages[4], old.messages[5] };
    source[5].images = &.{image};
    var h = try History.copy(a, &source, "");
    defer h.deinit();
    var service: c.Service = .{};
    defer service.deinit();
    var vision = config("http://127.0.0.1:18987/image");
    vision.vision = true;
    vision.image_token_reservation = 256;
    try service.start(vision, id, &h);
    try awaitResult(&service, &h, id, false);
    try std.testing.expectEqual(c.Status.succeeded, service.status);
    try std.testing.expectEqualSlices(u8, png, h.messages[3].images[0].content().?.bytes);
    try std.testing.expectEqual(@as(usize, 0), h.messages[0].tool_calls.len);
    // Switching to a model without vision fails before transmission; no pixels
    // or transcript content may be silently discarded to make a summary fit.
    var unsupported = try History.copy(a, &source, "");
    defer unsupported.deinit();
    const original = c.fingerprint(unsupported.messages);
    try service.start(config("http://127.0.0.1:18987/unsupported-image"), id, &unsupported);
    try awaitResult(&service, &unsupported, id, false);
    try std.testing.expectEqual(c.Status.failed, service.status);
    try std.testing.expectEqual(error.ModelDoesNotSupportImages, service.failure.?);
    try std.testing.expectEqual(original, c.fingerprint(unsupported.messages));
}

test "compaction real HTTP short single turn over window splits image summaries" {
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++ "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++ "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++ "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
    var image = try @import("ai/image_attachments.zig").ContentRef.create(a, "observation.png", png, 0, .{});
    defer image.release();
    var h = try History.copy(a, &.{.{ .content = "single user turn", .images = &.{ image, image, image, image } }}, "");
    defer h.deinit();
    var vision = config("http://127.0.0.1:18987/batch");
    vision.vision = true;
    vision.image_token_reservation = 10000;
    var service: c.Service = .{};
    defer service.deinit();
    try service.start(vision, id, &h);
    try awaitResult(&service, &h, id, false);
    try std.testing.expectEqual(c.Status.succeeded, service.status);
    try std.testing.expect(service.before_tokens > vision.context_window);
    try std.testing.expect(service.after_tokens < 1000);
    try std.testing.expectEqual(@as(usize, 1), h.messages.len);
    try std.testing.expectEqual(@as(usize, 0), h.messages[0].images.len);
    // The same threshold also compacts on the worker before a provider round.
    const Loop = @import("ai/tool_loop.zig").Loop;
    var loop = Loop.init(a, .{ .owner = .{ .session = 101 }, .members = .{} }, 1, .{ .context_window = vision.context_window });
    defer loop.deinit();
    loop.compaction_config = vision;
    const source = [_]p.Message{.{ .content = "single user turn", .images = &.{ image, image, image, image } }};
    try loop.start(vision.chatRequest(.{ .model = vision.model, .system = "", .messages = &source, .max_output = 2048 }));
    const next = try loop.nextRequest();
    try std.testing.expectEqual(@as(usize, 1), next.messages.len);
    try std.testing.expect(std.mem.startsWith(u8, next.messages[0].content, c.memory_prefix));
    try std.testing.expectEqual(@as(usize, 0), next.messages[0].images.len);
    var failed = Loop.init(a, .{ .owner = .{ .session = 101 }, .members = .{} }, 2, .{ .context_window = vision.context_window });
    defer failed.deinit();
    var failing_config = vision;
    failing_config.endpoint = "http://127.0.0.1:18987/worker-failure";
    failed.compaction_config = failing_config;
    const original = c.fingerprint(&source);
    try std.testing.expectError(error.ContextCompactionFailed, failed.start(vision.chatRequest(.{ .model = vision.model, .system = "", .messages = &source, .max_output = 2048 })));
    try std.testing.expectEqual(original, c.fingerprint(failed.messages.items));
    try std.testing.expectEqual(@as(usize, 4), failed.messages.items[0].images.len);
    try std.testing.expectError(error.ContextCompactionFailed, failed.checkRequestBudget());
    try std.testing.expectError(error.ContextCompactionFailed, failed.checkRequestBudget());
    try std.testing.expectEqual(original, c.fingerprint(failed.messages.items));
}

test "compaction threshold counts output headroom at ninety percent" {
    try std.testing.expect(!c.reachesThreshold(859, 40, 1000));
    try std.testing.expect(c.reachesThreshold(860, 40, 1000));
    try std.testing.expect(c.reachesThreshold(1050, 40, 1000));
    try std.testing.expectEqual(@as(usize, 1), c.cutoff(&.{.{ .content = "one large turn" }}).?);
}

test "compaction real HTTP enabled provider with no models discovers the full usable list" {
    var providers = [_]@import("config/config.zig").AiProvider{.{ .name = "discovery", .enabled = true, .endpoint = "http://127.0.0.1:18987/v1" }};
    const ai: @import("config/config.zig").Ai = .{ .providers = &providers, .provider_count = 1, .default_provider = "discovery" };
    var discovery: @import("ai/model_discovery.zig").Service = .{};
    defer discovery.deinit();
    _ = try discovery.poll(ai, 1, 0);
    for (0..5000) |_| {
        if (try discovery.poll(ai, 1, 0)) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
    const effective = discovery.effective(ai, 1);
    try std.testing.expectEqual(@as(usize, 2), effective.providers[0].model_count);
    const pc = @import("ai/provider_config.zig");
    const alpha = try pc.fromSettingsSelection(effective, .{ .provider_id = "discovery", .model_id = "alpha" });
    const beta = try pc.fromSettingsSelection(effective, .{ .provider_id = "discovery", .model_id = "beta" });
    try std.testing.expectEqualStrings("alpha", alpha.model);
    try std.testing.expectEqualStrings("beta", beta.model);
    try std.testing.expectEqual(@as(u32, 65536), beta.context_window);
    try std.testing.expectEqual(@as(usize, 0), ai.providers[0].model_count);
}

test "compaction real HTTP nonshrinking recursive summaries stop without repeating the same data" {
    const text = try a.alloc(u8, 45000);
    defer a.free(text);
    @memset(text, 'x');
    var h = try History.copy(a, &.{.{ .content = text }}, "");
    defer h.deinit();
    const original = c.fingerprint(h.messages);
    var selected = config("http://127.0.0.1:18987/limit");
    selected.context_window = 8192;
    var service: c.Service = .{};
    defer service.deinit();
    try service.start(selected, id, &h);
    try awaitResult(&service, &h, id, false);
    try std.testing.expectEqual(c.Status.failed, service.status);
    try std.testing.expectEqual(error.SummaryDidNotReduceContext, service.failure.?);
    try std.testing.expectEqual(original, c.fingerprint(h.messages));
}
