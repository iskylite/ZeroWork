//! Local image admission uses documented estimates or a conservative reservation,
//! never compressed bytes / 4 or fabricated provider usage.
//! https://developers.openai.com/api/docs/guides/images-vision#tile-based-image-tokenization
const std = @import("std");
const provider = @import("provider.zig");
const images = @import("image_attachments.zig");
pub const max_reservation = 128 * 1024;
/// Local admission reservation for a declared vision model whose tokenizer is
/// unknown. It is deliberately conservative, bounded by the same per-image
/// reservation limit, and is never provider-reported usage. Image count, wire
/// size and the request's context window are still checked independently.
pub const unknown_model_reservation = max_reservation;
pub fn validReservation(value: u32) bool {
    return value > 0 and value <= max_reservation;
}
pub fn supportsWithReservation(model: []const u8, reservation: ?u32) bool {
    return supports(model) or (if (reservation) |value| validReservation(value) else true);
}
pub fn supports(model: []const u8) bool {
    return std.mem.eql(u8, model, "gpt-4o-mini") or std.mem.eql(u8, model, "gpt-4o") or std.mem.eql(u8, model, "gpt-4.1");
}
pub fn tokens(model: []const u8, content: images.Content) !usize {
    if (content.width == 0 or content.height == 0) return error.InvalidImage;
    var base: usize = 85;
    var tile: usize = 170;
    if (std.mem.eql(u8, model, "gpt-4o-mini")) {
        base = 2833;
        tile = 5667;
    } else if (!std.mem.eql(u8, model, "gpt-4o") and !std.mem.eql(u8, model, "gpt-4.1")) return error.UnknownImageBudget;
    var width: f64 = @floatFromInt(content.width);
    var height: f64 = @floatFromInt(content.height);
    const fit = @min(1, 2048 / @max(width, height));
    width *= fit;
    height *= fit;
    const short = @min(1, 768 / @min(width, height));
    width = @floor(width * short);
    height = @floor(height * short);
    const columns: usize = @intFromFloat(@ceil(width / 512));
    const rows: usize = @intFromFloat(@ceil(height / 512));
    return base + tile * columns * rows;
}
pub fn validate(request: provider.ChatRequest) !usize {
    var total: usize = 0;
    for (request.messages) |message| {
        if (message.images.len == 0) continue;
        if (!request.vision) return error.ModelDoesNotSupportImages;
        if (message.role != .user and message.role != .tool or message.images.len > images.max_count) return error.InvalidImageMessage;
        if (message.role == .tool and !request.tool_images) return error.ModelDoesNotSupportToolImages;
        for (message.images) |reference| {
            const content = reference.content() orelse return error.EmptyAttachmentResult;
            if (content.bytes.len > images.max_bytes) return error.ImageTooLarge;
            const within_calibration = if (request.image_token_max_width) |width| if (request.image_token_max_height) |height| content.width <= width and content.height <= height else false else request.image_token_max_height == null;
            const reserved = tokens(request.model, content) catch |err| if (err == error.UnknownImageBudget) @as(usize, if (within_calibration) request.image_token_reservation orelse unknown_model_reservation else unknown_model_reservation) else return err;
            if (reserved == 0 or reserved > max_reservation) return error.UnknownImageBudget;
            total = std.math.add(usize, total, reserved) catch return error.RequestTooLarge;
        }
    }
    return total;
}
