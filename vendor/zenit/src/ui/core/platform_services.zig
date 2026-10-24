//! System clipboard and file dialogs: system_sdk facade for `Cx`.
//! These only touch `Cx.system_sdk`. Keeping them as `Cx` methods lets any component with `*Cx`
//! reach the clipboard and makes the logic untestable without a full `Cx`.
//! Here, functions take `?*SystemSdk` directly, so:
//! - Mock/null sdk allows independent unit testing of both "no SDK" and "SDK error" paths
//! - Methods on `Cx` are simple forwards
//!
//! Most entries compress failure to `false`/`null`/zero-value (unavailable clipboard shouldn't
//! crash UI), except `clipboardGetTextAllocChecked`, which keeps a real error union so callers
//! can distinguish "no text" from "read/alloc failure".

const std = @import("std");
const system_sdk_mod = @import("system_sdk");

const Sdk = system_sdk_mod.SystemSdk;

// -- File dialogs --

pub fn fileDialogAvailable(sdk_opt: ?*Sdk) bool {
    const sdk = sdk_opt orelse return false;
    return sdk.getCapabilities().has(.file_dialog);
}

/// Pop native "open file" dialog (sync blocking until user selects/cancels). Returns path slice
/// written to buffer; null = no SDK / unsupported / user cancelled / error.
pub fn openFilePanel(sdk_opt: ?*Sdk, buffer: []u8) ?[]const u8 {
    const sdk = sdk_opt orelse return null;
    return (sdk.runDialog(.{ .kind = .open_file }, buffer) catch return null) orelse null;
}

// -- Clipboard --

pub fn clipboardAvailable(sdk_opt: ?*Sdk) bool {
    const sdk = sdk_opt orelse return false;
    return sdk.getCapabilities().has(.clipboard);
}

/// Write to system clipboard. false = no SDK or write failure.
pub fn clipboardSetText(sdk_opt: ?*Sdk, clip_text: []const u8) bool {
    const sdk = sdk_opt orelse return false;
    sdk.clipboardSetText(clip_text) catch return false;
    return true;
}

/// Read system clipboard into caller's buffer.
pub fn clipboardGetText(sdk_opt: ?*Sdk, buffer: []u8) ?[]const u8 {
    const sdk = sdk_opt orelse return null;
    return sdk.clipboardGetText(buffer) catch null;
}

/// Dynamic allocation version. Caller responsible for release (or use frame_arena).
pub fn clipboardGetTextAlloc(sdk_opt: ?*Sdk, alloc: std.mem.Allocator) ?[]const u8 {
    return clipboardGetTextAllocChecked(sdk_opt, alloc) catch null;
}

/// Checked variant: null means no text; missing SDK/support and read or
/// allocation failures remain distinguishable. Caller frees nonempty text.
pub fn clipboardGetTextAllocChecked(
    sdk_opt: ?*Sdk,
    alloc: std.mem.Allocator,
) system_sdk_mod.SdkError!?[]const u8 {
    const sdk = sdk_opt orelse return error.NotSupported;
    return sdk.clipboardGetTextAlloc(alloc);
}

/// Probe clipboard for available types (text/image/file_urls). No decoding; query on-demand during
/// Cmd+V.
pub fn clipboardProbe(sdk_opt: ?*Sdk) system_sdk_mod.ClipboardKinds {
    const sdk = sdk_opt orelse return .{};
    return sdk.clipboardProbe() catch .{};
}

/// Count clipboard image items (supports Finder multi-select copy); 0 if unsupported.
pub fn clipboardImageCount(sdk_opt: ?*Sdk) usize {
    const sdk = sdk_opt orelse return 0;
    return sdk.clipboardImageCount() catch 0;
}

/// Read clipboard image at index (premultiplied RGBA8 + raw encoded bytes). null = no image or
/// unsupported. Release with `ClipboardImage.deinit(alloc)`.
pub fn clipboardGetImageAlloc(
    sdk_opt: ?*Sdk,
    alloc: std.mem.Allocator,
    index: usize,
) ?system_sdk_mod.ClipboardImage {
    const sdk = sdk_opt orelse return null;
    return sdk.clipboardGetImageAlloc(alloc, index) catch null;
}

/// Write PNG-encoded image to clipboard; false = unsupported or failure.
pub fn clipboardSetImagePng(sdk_opt: ?*Sdk, png_bytes: []const u8) bool {
    const sdk = sdk_opt orelse return false;
    sdk.clipboardSetImagePng(png_bytes) catch return false;
    return true;
}

// -- Tests --
// The null-SDK path (sdk == null) is the only code path that can be independently verified without
// real system access—and it's what hosts actually hit in headless/test environments. Every entry
// point must degrade safely rather than panic; this is the contract the tests below pin down.

test "无 SDK 时全部入口安全降级" {
    const alloc = std.testing.allocator;
    var buf: [64]u8 = undefined;

    try std.testing.expect(!fileDialogAvailable(null));
    try std.testing.expectEqual(@as(?[]const u8, null), openFilePanel(null, &buf));

    try std.testing.expect(!clipboardAvailable(null));
    try std.testing.expect(!clipboardSetText(null, "x"));
    try std.testing.expectEqual(@as(?[]const u8, null), clipboardGetText(null, &buf));
    try std.testing.expectEqual(@as(?[]const u8, null), clipboardGetTextAlloc(null, alloc));
    try std.testing.expectEqual(@as(usize, 0), clipboardImageCount(null));
    try std.testing.expectEqual(@as(?system_sdk_mod.ClipboardImage, null), clipboardGetImageAlloc(null, alloc, 0));
    try std.testing.expect(!clipboardSetImagePng(null, "png"));

    // probe returns empty set, not panic or false positive.
    const kinds = clipboardProbe(null);
    try std.testing.expect(!kinds.text);
    try std.testing.expect(!kinds.image);
}

test "无 SDK 时 checked 变体保留可区分的错误" {
    // Unchecked version compresses all failures to null; checked version lets caller distinguish
    // "no text" from "no SDK".
    try std.testing.expectError(
        error.NotSupported,
        clipboardGetTextAllocChecked(null, std.testing.allocator),
    );
}
