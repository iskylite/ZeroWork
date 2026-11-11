//! Snapshot a native image paste without decoding pixels on the UI thread.
const std = @import("std");
const ui = @import("ui");
const assets = @import("assets.zig");
const ImportInput = @import("editor_images.zig").ImportInput;

const Result = enum(c_int) {
    empty = 0,
    bytes = 1,
    file = 2,
    too_large = -1,
    out_of_memory = -2,
    invalid_image = -3,
    invalid_path = -4,
};

extern "c" fn zw_notes_copy_clipboard_image(limit: usize, bytes: *?[*]u8, count: *usize) Result;

pub const ClipboardInput = struct {
    input: ImportInput,

    pub fn deinit(self: *ClipboardInput) void {
        const owned = switch (self.input) {
            .clipboard, .file => |value| value,
        };
        std.c.free(@constCast(owned.ptr));
        self.* = undefined;
    }
};

/// Call on the UI thread only while handling a paste in the notes editor.
/// Null leaves the regular Textarea text paste path in control.
pub fn read(cx: *ui.Cx) !?ClipboardInput {
    if (!ui.platform_services.clipboardAvailable(cx.system_sdk)) return null;
    var bytes: ?[*]u8 = null;
    var count: usize = 0;
    switch (zw_notes_copy_clipboard_image((assets.Limits{}).effective().bytes, &bytes, &count)) {
        .empty => return null,
        .too_large => return error.ImageTooLarge,
        .out_of_memory => return error.OutOfMemory,
        .invalid_image => return error.UnsupportedImage,
        .invalid_path => return error.InvalidAttachmentPath,
        .bytes => return .{ .input = .{ .clipboard = bytes.?[0..count] } },
        .file => return .{ .input = .{ .file = bytes.?[0..count] } },
    }
}
