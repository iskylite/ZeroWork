const std = @import("std");
const images = @import("ai/image_attachments.zig");
const host = @import("host/ai_image_snapshot.zig");
const provider = @import("ai/provider.zig");
const http = @import("ai/provider_http.zig");
const budget = @import("ai/local_text_request.zig");
const a = std.testing.allocator;
const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
    "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++
    "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
const corrupt = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
    "\x00\x00\x00\x08IDATbad-zlib\xa9\xbf\xb9\xcf" ++
    "\x00\x00\x00\x00IEND\xae\x42\x60\x82";

test "images actual file MIME decode immutable pixels and source failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wrong-extension.txt", .data = png });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "wrong-extension.txt", a);
    defer a.free(path);
    var cancel: provider.CancelToken = .{};
    var ref = try host.capture(a, std.testing.io, path, &cancel, .{});
    defer ref.release();
    try std.testing.expectEqual(images.Mime.png, ref.content().?.mime);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, ref.content().?.pixels);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wrong-extension.txt", .data = corrupt });
    try std.testing.expectError(error.InvalidImage, host.capture(a, std.testing.io, path, &cancel, .{}));
    try std.testing.expectEqualStrings(png, ref.content().?.bytes);
    try std.testing.expectError(error.ImageTooLarge, images.ContentRef.create(a, path, png, 1, .{ .bytes = png.len - 1 }));
    try std.testing.expectError(error.ImageTooLarge, images.ContentRef.create(a, path, png, 1, .{ .dimension = 0 }));
    try std.testing.expectError(error.ImageTooLarge, images.ContentRef.create(a, path, png, 1, .{ .pixels = 0 }));
    try std.testing.expectError(error.UnsupportedImage, images.ContentRef.create(a, path, "fake PNG", 1, .{}));
    cancel.cancel();
    try std.testing.expectError(error.Cancelled, host.capture(a, std.testing.io, path, &cancel, .{}));
}

test "images four slots include processing errors retry keeps slot late callbacks cannot revive owner" {
    var draft = try images.Draft.init(a, .{ .session = 9 });
    defer draft.deinit();
    const first = try draft.begin("/fixture.png", .{});
    try std.testing.expectError(error.ImageNotRetryable, draft.retry(first));
    try std.testing.expect(draft.fail(first, error.AccessDenied));
    const retry = try draft.retry(first);
    try std.testing.expect(!draft.fail(first, error.InvalidImage));
    var ref = try images.ContentRef.create(a, "/fixture.png", png, 1, .{});
    try draft.complete(retry, &ref);
    for (0..3) |_| _ = try draft.begin("/other.png", .{});
    try std.testing.expectError(error.TooManyImages, draft.begin("/fifth.png", .{}));
    try std.testing.expectError(error.AttachmentsProcessing, draft.freeze());
    while (draft.items.items.len > 1) _ = draft.remove(draft.items.items[1].ticket.id);
    var sent = try draft.freeze();
    defer sent.deinit();
    try std.testing.expectEqual(@as(usize, 1), try draft.consumeSent(&sent));
    try std.testing.expectEqualStrings(png, sent.items[0].reference.content().?.bytes);
    const late = try draft.begin("/fixture.png", .{});
    try draft.clear();
    var stale = try images.ContentRef.create(a, "/fixture.png", png, 1, .{});
    try std.testing.expectError(error.StaleAttachment, draft.complete(late, &stale));
    try std.testing.expect(stale.content() == null);
    try std.testing.expectEqual(@as(usize, 0), draft.items.items.len);
    _ = try draft.begin("/one.png", .{ .count = 1 });
    try std.testing.expectError(error.TooManyImages, draft.begin("/two.png", .{ .count = 1 }));
}

test "images real multimodal JSON has exact raster base64 full count and documented tokens" {
    var reference = try images.ContentRef.create(a, "/fixture.png", png, 1, .{});
    defer reference.release();
    const messages = [_]provider.Message{.{ .content = "what color?", .images = &.{reference} }};
    var request: provider.ChatRequest = .{ .model = "gpt-4o", .vision = true, .system = "", .messages = &messages, .max_output = 1 };
    const body = try http.requestBody(a, .openai_compat, request, 8192);
    defer a.free(body);
    try std.testing.expectEqual(body.len, try http.requestBodySize(.openai_compat, request, 8192));
    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const content = parsed.value.object.get("messages").?.array.items[0].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), content.len);
    const data_url = content[1].object.get("image_url").?.object.get("url").?.string;
    const prefix = "data:image/png;base64,";
    try std.testing.expect(std.mem.startsWith(u8, data_url, prefix));
    const b64 = data_url[prefix.len..];
    const decoded = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(b64));
    defer a.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, b64);
    try std.testing.expectEqualStrings(png, decoded);
    try std.testing.expectEqual(@as(usize, 266), try budget.inputTokens(request));
    try std.testing.expectError(error.ContextBudgetExceeded, budget.checkContext(request, 266));
    request.vision = false;
    try std.testing.expectError(error.ModelDoesNotSupportImages, http.requestBodySize(.openai_compat, request, 8192));
    request.vision = true;
    request.model = "mimo-v2.6-flash";
    try std.testing.expectError(error.UnknownImageBudget, http.requestBodySize(.openai_compat, request, 8192));
}

fn oomImage(allocator: std.mem.Allocator) !void {
    var ref = try images.ContentRef.create(allocator, "/fixture.png", png, 1, .{});
    defer ref.release();
    var draft = try images.Draft.init(allocator, .{ .group = 4 });
    defer draft.deinit();
    const ticket = try draft.begin("/fixture.png", .{});
    try draft.complete(ticket, &ref);
    var bundle = try draft.freeze();
    defer bundle.deinit();
    var retained = try bundle.retain();
    defer retained.deinit();
}
test "images OOM allocations release decoded pixels paths bytes and bundles" {
    try std.testing.checkAllAllocationFailures(a, oomImage, .{});
}

test "images reader cancelled completed worker cannot deliver success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pixel.png", .data = png });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "pixel.png", a);
    defer a.free(path);
    const ticket: images.Ticket = .{ .owner = .{ .session = 1 }, .draft_epoch = 1, .id = 1 };
    const reader = try host.Reader.start(std.heap.c_allocator, ticket, path, .{});
    defer reader.deinit();
    reader.cancel();
    while (!reader.poll()) std.Thread.yield() catch {};
    const completion = reader.take().?;
    try std.testing.expectError(error.Cancelled, completion.result);
    try std.testing.expect(reader.take() == null);
}

test "images decimal 10000000 byte source ceiling is exact and base64 wire counts every byte" {
    const bytes = try a.alloc(u8, images.max_bytes + 1);
    defer a.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..png.len], png);
    var ref = try images.ContentRef.create(a, "/chosen/padded.png", bytes[0..images.max_bytes], 1, .{});
    defer ref.release();
    try std.testing.expectEqual(@as(usize, 10_000_000), ref.content().?.bytes.len);
    try std.testing.expectError(error.ImageTooLarge, images.ContentRef.create(a, "/chosen/padded.png", bytes, 1, .{}));
    const request: provider.ChatRequest = .{ .model = "gpt-4o", .vision = true, .system = "", .messages = &.{.{ .content = "all source bytes", .images = &.{ref} }} };
    const count = try http.requestBodySize(.openai_compat, request, 8192);
    try std.testing.expect(count > std.base64.standard.Encoder.calcSize(images.max_bytes));
    try std.testing.expect(count < std.base64.standard.Encoder.calcSize(images.max_bytes) + 1024);
    try std.testing.expect(try budget.inputTokens(request) < 512);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "oversize.png", .data = bytes });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "oversize.png", a);
    defer a.free(path);
    try std.testing.expectError(error.ImageTooLarge, host.preflight(std.testing.io, path, .{}));
}

test "images pasted snapshot retry never rereads a changed clipboard" {
    var draft = try images.Draft.init(a, .{ .group = 22 });
    defer draft.deinit();
    var mutable: [png.len]u8 = png[0..png.len].*;
    const ticket = try draft.beginBytes("粘贴图片.png", &mutable, .{});
    @memset(&mutable, 'x');
    try std.testing.expectEqualStrings(png, draft.find(ticket).?.source_bytes.?);
    try std.testing.expect(draft.fail(ticket, error.OutOfMemory));
    const retry = try draft.retry(ticket);
    var token: provider.CancelToken = .{};
    var reference = try host.captureBytes(a, "粘贴图片.png", draft.find(retry).?.source_bytes.?, &token, .{});
    try draft.complete(retry, &reference);
    try std.testing.expectEqualStrings(png, draft.find(retry).?.reference.content().?.bytes);
}

test "images real TIFF clipboard normalizes to an actual decoded PNG" {
    const tiff = "\x49\x49\x2a\x00\x08\x00\x00\x00\x0a\x00\x00\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00\x02\x01\x03\x00\x03\x00\x00\x00\x86\x00\x00\x00\x03\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00\x06\x01\x03\x00\x01\x00\x00\x00\x02\x00\x00\x00\x11\x01\x04\x00\x01\x00\x00\x00\x8c\x00\x00\x00\x15\x01\x03\x00\x01\x00\x00\x00\x03\x00\x00\x00\x16\x01\x04\x00\x01\x00\x00\x00\x01\x00\x00\x00\x17\x01\x04\x00\x01\x00\x00\x00\x03\x00\x00\x00\x1c\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x08\x00\x08\x00\x08\x00\xff\x00\x00";
    var token: provider.CancelToken = .{};
    var reference = try host.captureBytes(a, "粘贴图片.png", tiff, &token, .{});
    defer reference.release();
    const content = reference.content().?;
    try std.testing.expectEqual(images.Mime.png, content.mime);
    try std.testing.expectEqual(@as(u32, 1), content.width);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, content.pixels);
    try std.testing.expect(std.mem.startsWith(u8, content.bytes, "\x89PNG\r\n\x1a\n"));
}

test "images unavailable adapters and unknown model budgets fail before wire output without consuming history" {
    var reference = try images.ContentRef.create(a, "/fixture.png", png, 1, .{});
    defer reference.release();
    const request: provider.ChatRequest = .{ .model = "gpt-4o", .vision = true, .system = "", .messages = &.{.{ .content = "image", .images = &.{reference} }} };
    for ([_]@import("ai/registry.zig").Kind{ .anthropic, .ollama }) |kind| {
        try std.testing.expectError(error.UnsupportedImageProtocol, http.requestBodySize(kind, request, 8192));
    }
    var draft = try images.Draft.init(a, .{ .session = 101 });
    defer draft.deinit();
    const ticket = try draft.begin("/fixture.png", .{});
    var captured = reference.retain();
    try draft.complete(ticket, &captured);
    var bundle = try draft.freeze();
    defer bundle.deinit();
    const message = @import("ai/assistant_store.zig").Message{ .user = true, .text = @constCast("question"), .images = bundle };
    var history = try message.clone(a);
    defer history.deinit(a);
    _ = try draft.consumeSent(&bundle);
    bundle.deinit();
    try std.testing.expectEqualStrings(png, history.images.?.items[0].reference.content().?.bytes);
    var unknown = request;
    unknown.model = "mimo-v2.6-flash";
    try std.testing.expectError(error.UnknownImageBudget, http.requestBodySize(.openai_compat, unknown, 8192));
    try std.testing.expectEqualStrings(png, history.images.?.items[0].reference.content().?.bytes);
}
