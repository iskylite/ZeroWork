//! Main-thread GPU admission for already decoded background pixels. Keep the
//! old Texture alive until the shared configuration transaction has committed.
const std = @import("std");
const App = @import("zenit_app").App;
const Prepared = @import("../config/background_asset.zig").Prepared;
const repeat = @import("background_repeat.zig");

pub const Texture = struct {
    app: *App,
    id: u32,
    width: u32,
    height: u32,
    repeating: ?repeat.Texture = null,

    pub fn deinit(self: *Texture) void {
        if (self.repeating) |texture| self.app.renderer.image_renderer.unloadTexture(texture.id);
        self.app.renderer.image_renderer.unloadTexture(self.id);
        self.* = undefined;
    }
};

/// No file access or decoding here. GPU allocation/budget errors are returned
/// before settings persistence, so callers can retain their last good texture.
pub fn upload(app: *App, prepared: *const Prepared) !Texture {
    const image = prepared.image;
    if (image.width == 0 or image.height == 0) return error.InvalidImage;
    const pixels = try std.math.mul(usize, image.width, image.height);
    const bytes = try std.math.mul(usize, pixels, 4);
    if (image.pixels.len != bytes) return error.InvalidImage;
    const id = try app.renderer.image_renderer.loadTexture(image.width, image.height, image.pixels);
    errdefer app.renderer.image_renderer.unloadTexture(id);
    var repeating: ?repeat.Texture = null;
    if (try repeat.expand(app.allocator, image.width, image.height, image.pixels)) |expanded| {
        defer app.allocator.free(expanded.rgba);
        const repeated_id = try app.renderer.image_renderer.loadTexture(expanded.width, expanded.height, expanded.rgba);
        repeating = .{ .id = repeated_id, .width = expanded.width, .height = expanded.height };
    }
    return .{ .app = app, .id = id, .width = image.width, .height = image.height, .repeating = repeating };
}
