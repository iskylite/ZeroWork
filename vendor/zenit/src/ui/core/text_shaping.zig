//! Pure-function part of text shaping, extracted from Cx.
//!
//! shapeText / shapeVisualLine / visualLine / measureTextWidth on Cx need
//! font_system + shaping_cache + allocator and stay on Cx (they are Cx's text API).
//! Their three helpers are pure: fixed input -> fixed output, no context state.
//!
//! Extraction allows:
//!   1. Direct unit testing: each function hides a hard-won invariant (see their
//!      comments), which can't be verified by running a whole Cx.
//!   2. Explicit homes for the invariants.

const std = @import("std");
const shaping_cache = @import("shaping_cache.zig");
const text_module = @import("text");
const utf8 = @import("text_core").utf8;

pub const ShapingKey = shaping_cache.ShapingKey;

/// Shaping input. font_family participates in cache key (see shapingKey).
pub const ShapeTextOpts = struct {
    text: []const u8,
    font_family: []const u8,
    font_size: f32,
    font_weight: u16 = 400,
    use_italic: bool = false,
    /// Registry id; zero uses the named/default family.
    font_family_id: u16 = 0,
    use_monospace: bool = false,
    use_symbols: bool = false,
};

/// Trim to the longest complete UTF-8/WTF-8 storage prefix.
///
/// Gotcha: a caller slicing by byte may land mid-multibyte sequence (half a CJK/emoji).
/// Invalid UTF-8 fails CoreText NSString construction, the shaping layer reports
/// TextShapingFailed, the FontSelector bridge silently returns 0.0f, and the final
/// width 0.00 collapses the bbox. Trimming to the longest valid prefix matches the
/// actual render output; valid input passes through with zero overhead.
pub fn validUtf8Prefix(bytes: []const u8) []const u8 {
    return utf8.validStoragePrefix(bytes);
}

/// Compute shaping cache key.
///
/// Warning: family must be in the key. Otherwise the same text under a different
/// family (e.g., a font picker preview list) hits the **previous family's** cache
/// entry and lines 2+ render in line 1's font.
///
/// family is hashed separately into font_id (not merged with text_hash):
/// ShapingKey.eq compares field by field, so two fields lower collision and clarify
/// key semantics.
pub fn shapingKey(opts: ShapeTextOpts) ShapingKey {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(opts.text);
    var weight_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &weight_buf, opts.font_weight, .little);
    hasher.update(&weight_buf);
    const italic_byte: [1]u8 = .{if (opts.use_italic) 1 else 0};
    hasher.update(&italic_byte);
    var fam_hasher = std.hash.Wyhash.init(0x46414d49); // "FAMI"
    fam_hasher.update(opts.font_family);
    fam_hasher.update(std.mem.asBytes(&opts.font_family_id));
    const kind_flags: [1]u8 = .{(if (opts.use_monospace) @as(u8, 1) else 0) | (if (opts.use_symbols) @as(u8, 2) else 0)};
    fam_hasher.update(&kind_flags);
    return .{
        .text_hash = hasher.final(),
        .text_len = @intCast(opts.text.len),
        .font_id = @truncate(fam_hasher.final()),
        .max_width = 0,
        .font_size = opts.font_size,
    };
}

/// CSS numeric font-weight -> platform weight enum.
pub fn mapFontWeight(weight: u16) text_module.FontWeight {
    return if (weight <= 100) .thin else if (weight <= 300) .light else if (weight <= 400) .regular else if (weight <= 500) .medium else if (weight <= 600) .semibold else if (weight <= 700) .bold else if (weight <= 800) .heavy else .black;
}

// -- Tests -------

test "validUtf8Prefix: 合法输入原样返回" {
    try std.testing.expectEqualStrings("hello", validUtf8Prefix("hello"));
    try std.testing.expectEqualStrings("中文", validUtf8Prefix("中文"));
    try std.testing.expectEqualStrings("", validUtf8Prefix(""));
}

test "validUtf8Prefix: 切在多字节序列中间时裁到上一个完整字符" {
    // U+4E2D = E4 B8 AD, trim last byte
    const cut = "\xE4\xB8";
    try std.testing.expectEqualStrings("", validUtf8Prefix(cut));

    // "a" + U+4E2D with last byte of U+4E2D removed -> just "a"
    const mixed = "a\xE4\xB8";
    try std.testing.expectEqualStrings("a", validUtf8Prefix(mixed));
}

test "validUtf8Prefix: emoji 后切在 CJK 首字节（下游应用实测塌 bbox 的那个形状）" {
    // U+1F600 = F0 9F 98 80, followed by half of U+4E2D
    const s = "\xF0\x9F\x98\x80\xE4";
    try std.testing.expectEqualStrings("\xF0\x9F\x98\x80", validUtf8Prefix(s));
}

test "validUtf8Prefix: 完全非法的首字节返回空" {
    try std.testing.expectEqualStrings("", validUtf8Prefix("\xFF\xFE"));
}

test "shapingKey: family 必须参与 key（换族不得命中旧条目）" {
    const a = shapingKey(.{ .text = "Ag", .font_family = "system", .font_size = 14 });
    const b = shapingKey(.{ .text = "Ag", .font_family = "Menlo", .font_size = 14 });
    try std.testing.expect(a.font_id != b.font_id);
}

test "shapingKey: text/size/weight/italic 各自参与 key" {
    const base = ShapeTextOpts{ .text = "Ag", .font_family = "system", .font_size = 14, .font_weight = 400 };
    const k = shapingKey(base);

    var other = base;
    other.text = "Ah";
    try std.testing.expect(shapingKey(other).text_hash != k.text_hash);

    other = base;
    other.font_weight = 700;
    try std.testing.expect(shapingKey(other).text_hash != k.text_hash);

    other = base;
    other.use_italic = true;
    try std.testing.expect(shapingKey(other).text_hash != k.text_hash);

    other = base;
    other.font_size = 18;
    try std.testing.expect(shapingKey(other).font_size != k.font_size);
}

test "shapingKey: 相同输入稳定复现" {
    const o = ShapeTextOpts{ .text = "stable", .font_family = "system", .font_size = 13, .font_weight = 500 };
    const a = shapingKey(o);
    const b = shapingKey(o);
    try std.testing.expectEqual(a.text_hash, b.text_hash);
    try std.testing.expectEqual(a.font_id, b.font_id);
    try std.testing.expectEqual(a.text_len, b.text_len);
}

test "mapFontWeight: CSS 数值落到正确的枚举档位" {
    try std.testing.expectEqual(text_module.FontWeight.thin, mapFontWeight(100));
    try std.testing.expectEqual(text_module.FontWeight.light, mapFontWeight(300));
    try std.testing.expectEqual(text_module.FontWeight.regular, mapFontWeight(400));
    try std.testing.expectEqual(text_module.FontWeight.medium, mapFontWeight(500));
    try std.testing.expectEqual(text_module.FontWeight.semibold, mapFontWeight(600));
    try std.testing.expectEqual(text_module.FontWeight.bold, mapFontWeight(700));
    try std.testing.expectEqual(text_module.FontWeight.heavy, mapFontWeight(800));
    try std.testing.expectEqual(text_module.FontWeight.black, mapFontWeight(900));
    // boundary: tier is <=, so 401 should fall into next tier
    try std.testing.expectEqual(text_module.FontWeight.medium, mapFontWeight(401));
}

test "shapingKey distinguishes registry family ids and font kinds" {
    const base = ShapeTextOpts{ .text = "AV ffi Windows", .font_family = "system", .font_size = 16 };
    var family = base;
    family.font_family_id = 1;
    var other = family;
    other.font_family_id = 2;
    var mono = family;
    mono.use_monospace = true;
    var symbols = family;
    symbols.use_symbols = true;
    try std.testing.expect(!ShapingKey.eq(shapingKey(base), shapingKey(family)));
    try std.testing.expect(!ShapingKey.eq(shapingKey(family), shapingKey(other)));
    try std.testing.expect(!ShapingKey.eq(shapingKey(family), shapingKey(mono)));
    try std.testing.expect(!ShapingKey.eq(shapingKey(family), shapingKey(symbols)));
    try std.testing.expect(ShapingKey.eq(shapingKey(family), shapingKey(family)));
}

test "validUtf8Prefix: WTF8 storage remains complete for native projection" {
    const stored = "A\xed\xa0\x80Z";
    try std.testing.expectEqualStrings(stored, validUtf8Prefix(stored));
    try std.testing.expectEqualStrings(stored, validUtf8Prefix(stored ++ "\xed\xa0"));
    try std.testing.expect(!utf8.isValid(stored));
}
