//! font_catalog.zig: system font directory (data layer for the font picker).
//! Enumerates installed system font families and answers one question per family:
//! **"What should this line render to show the user what this font looks like?"**
//!
//! == Why it's not just "render the family name in that font" ==
//!
//! Measured on macOS (272 families / 990 faces):
//!   - **47 families (17%) cannot render their own name**: Arabic/Hebrew/Devanagari/
//!     CJK/Burmese/Tibetan... have Latin-letter names but no Latin glyphs, so self-render
//!     gives blank or tofu.
//!   - **9 symbol fonts** (Wingdings/Webdings/Zapf Dingbats/...) are trickier: they **have**
//!     'A' glyphs, so a glyph coverage check "passes", but they render graphics.
//!     The only reliable criterion is symbolic class.
//!
//! So `previewPlan()` routes each family to one of four paths; all 272 families have a
//! solution (see tests):
//!
//!   1. `.self`, render the name in the font itself (Latin fonts, mainstream)
//!   2. `.glyph_sample`, symbol fonts: name in UI font, plus a glyph sample
//!   3. `.lang_sample`, non-Latin: name in UI font, plus a language sample
//!   4. `.codepoints`, fallback: renderable codepoints from the font's character set
//!                      (only Noto Sans Batak / Tagalog fall here)
//!
//! == Usage ==
//! ```zig
//! var cat = try FontCatalog.scan(allocator);   // ~40ms, recommend background thread
//! defer cat.deinit();
//! for (cat.families) |fam| {
//!     switch (fam.previewPlan()) { ... }
//! }
//! ```
//!
//! Note: the render pipeline has no font family axis yet (TextProps / DisplayItem.text_run /
//! FontSelector have no family field); this layer only handles **enumeration and metadata**.

const std = @import("std");
const builtin = @import("builtin");
const bridge = @import("coretext/coretext_bridge.zig");

pub const FamilyClass = bridge.FamilyClass;

/// What to draw on this row in preview.
pub const PreviewPlan = union(enum) {
    /// Render family name in the font itself.
    self,
    /// Symbol fonts: family name in UI font, plus glyph sample in that font.
    /// Codepoints come from font's character set, guaranteed renderable.
    glyph_sample: []const u32,
    /// Non-Latin fonts: family name in UI font, plus language sample string (UTF-8).
    lang_sample: []const u8,
    /// Final fallback: family name in UI font, plus these codepoints.
    codepoints: []const u32,
};

pub const Family = struct {
    /// Family name; owned by catalog.
    name: []const u8,
    is_symbolic: bool,
    can_render_name: bool,
    is_variable: bool,
    face_count: u16,
    class: FamilyClass,
    /// BCP-47 language tag (e.g. "ar" / "zh-Hans"), empty = unknown.
    lang: []const u8,
    /// Has basic Latin glyphs; false = typing English yields blank/tofu.
    has_latin: bool,
    /// Fallback codepoints; non-empty only when lang is empty and sample needed.
    sample_cps: []const u32,

    /// Whether this font **makes sense for plain text**.
    ///
    /// All 272 families parse at the CoreText level (substituted=0), so none is truly unusable, but
    /// two
    /// types confuse users:
    ///   * Symbol fonts (9): typing 'hello' renders pictures;
    ///   * No Latin glyphs (43): typing English yields blank/tofu.
    /// The UI shows these as disabled (still clickable, e.g. for Arabic): a **hint**, not a
    /// **ban**.
    pub fn isUsableForLatinText(self: Family) bool {
        return self.has_latin and !self.is_symbolic;
    }

    /// What to draw on this row. Determination order matters; see file header.
    pub fn previewPlan(self: Family) PreviewPlan {
        // Symbol fonts take priority: can_render_name might be true, but false.
        if (self.is_symbolic) return .{ .glyph_sample = self.sample_cps };
        if (self.can_render_name) return .self;
        if (sampleForLang(self.lang)) |s| return .{ .lang_sample = s };
        return .{ .codepoints = self.sample_cps };
    }
};

/// Language tag -> short sample string for that language.
///
/// Covers only tags actually encountered in measurements (among 47 macOS families unable to render
/// their name, 41 provide tags: ar×20 he×5 my×2 bo×2 bgc×2 gu×2 zh/hy/kn/or/pa/brx/nqo/syr once
/// each). Returns null if not matched, falls back to codepoints, so this table **doesn't need to
/// enumerate all languages**, missing entries won't cause blank rows.
fn sampleForLang(tag: []const u8) ?[]const u8 {
    if (tag.len == 0) return null;
    // Match by primary language subtag ("zh-Hans" -> "zh").
    const primary = blk: {
        const dash = std.mem.indexOfScalar(u8, tag, '-') orelse break :blk tag;
        break :blk tag[0..dash];
    };
    const table = [_]struct { tag: []const u8, sample: []const u8 }{
        .{ .tag = "ar", .sample = "أبجد هوز" },
        .{ .tag = "he", .sample = "אבגד הוז" },
        .{ .tag = "fa", .sample = "الفبا" },
        .{ .tag = "ur", .sample = "الف بے" },
        .{ .tag = "syr", .sample = "ܐܒܓܕ" },
        .{ .tag = "nqo", .sample = "ߒߞߏ" },
        .{ .tag = "hi", .sample = "अआइई" },
        .{ .tag = "brx", .sample = "अआइई" },
        .{ .tag = "bgc", .sample = "अआइई" },
        .{ .tag = "mr", .sample = "अआइई" },
        .{ .tag = "ne", .sample = "अआइई" },
        .{ .tag = "kok", .sample = "अआइई" },
        .{ .tag = "gu", .sample = "અઆઇઈ" },
        .{ .tag = "pa", .sample = "ਅਆਇਈ" },
        .{ .tag = "bn", .sample = "অআইঈ" },
        .{ .tag = "or", .sample = "ଅଆଇଈ" },
        .{ .tag = "ta", .sample = "அஆஇஈ" },
        .{ .tag = "te", .sample = "అఆఇఈ" },
        .{ .tag = "kn", .sample = "ಅಆಇಈ" },
        .{ .tag = "ml", .sample = "അആഇഈ" },
        .{ .tag = "si", .sample = "අආඇඈ" },
        .{ .tag = "th", .sample = "กขคง" },
        .{ .tag = "lo", .sample = "ກຂຄງ" },
        .{ .tag = "my", .sample = "ကခဂဃ" },
        .{ .tag = "km", .sample = "កខគឃ" },
        .{ .tag = "bo", .sample = "ཀཁགང" },
        .{ .tag = "hy", .sample = "ԱԲԳԴ" },
        .{ .tag = "ka", .sample = "აბგდ" },
        .{ .tag = "am", .sample = "አለሐመ" },
        .{ .tag = "chr", .sample = "ᏣᎳᎩ" },
        .{ .tag = "iu", .sample = "ᐊᐃᐅ" },
        .{ .tag = "zh", .sample = "字体预览" },
        .{ .tag = "ja", .sample = "字体サンプル" },
        .{ .tag = "ko", .sample = "글꼴 견본" },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e.tag, primary)) return e.sample;
    }
    return null;
}

pub const FontCatalog = struct {
    allocator: std.mem.Allocator,
    families: []Family,
    /// Unified storage and cleanup for all family names/codepoints.
    arena: std.heap.ArenaAllocator,

    /// Scan system fonts. Measured ~40ms (272 families), **suggest background thread**.
    /// Non-macOS returns empty; enumeration bridge only implemented in CoreText backend.
    pub fn scan(allocator: std.mem.Allocator) !FontCatalog {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        if (builtin.target.os.tag != .macos) {
            return .{
                .allocator = allocator,
                .families = &.{},
                .arena = arena,
            };
        }

        const a = arena.allocator();
        const total = bridge.coretext_family_count();
        if (total <= 0) {
            return .{ .allocator = allocator, .families = &.{}, .arena = arena };
        }
        const count: usize = @intCast(total);

        // C-side strdup'd raw pointers, copied into arena and freed immediately.
        const raw = try allocator.alloc(?[*:0]u8, count);
        defer allocator.free(raw);
        @memset(raw, null);
        const got = bridge.coretext_copy_family_names(raw.ptr, @intCast(count));
        defer for (raw[0..@intCast(got)]) |p| {
            if (p) |nn| bridge.coretext_free_c_string(nn);
        };

        var list = try std.ArrayList(Family).initCapacity(a, @intCast(got));

        var i: usize = 0;
        while (i < @as(usize, @intCast(got))) : (i += 1) {
            const cname = raw[i] orelse continue;

            var info: bridge.CoreTextFamilyInfo = undefined;
            if (bridge.coretext_family_info(cname, &info) != 0) continue;
            // Families where descriptor can't find face (e.g. SF Pro) excluded; can't use if
            // selected.
            if (info.face_count == 0) continue;

            const name = try a.dupe(u8, std.mem.span(cname));

            const lang_len = std.mem.indexOfScalar(u8, &info.lang, 0) orelse info.lang.len;
            const lang = try a.dupe(u8, info.lang[0..lang_len]);

            const is_symbolic = info.is_symbolic != 0;
            const can_render = info.can_render_name != 0;

            // Only fetch codepoints for rows that actually need samples (extra CoreText round
            // trip).
            var cps: []const u32 = &.{};
            const needs_sample = is_symbolic or !can_render;
            if (needs_sample) {
                var buf: [8]u32 = undefined;
                const n = bridge.coretext_family_sample_codepoints(cname, &buf, buf.len);
                if (n > 0) cps = try a.dupe(u32, buf[0..@intCast(n)]);
            }

            try list.append(a, .{
                .name = name,
                .is_symbolic = is_symbolic,
                .can_render_name = can_render,
                .is_variable = info.is_variable != 0,
                .face_count = @intCast(@min(info.face_count, std.math.maxInt(u16))),
                .class = @fromBackingInt(@intCast(info.classification)),
                .lang = lang,
                .has_latin = info.has_latin != 0,
                .sample_cps = cps,
            });
        }

        const families = try list.toOwnedSlice(a);
        std.mem.sort(Family, families, {}, struct {
            fn lt(_: void, x: Family, y: Family) bool {
                return std.ascii.lessThanIgnoreCase(x.name, y.name);
            }
        }.lt);

        return .{ .allocator = allocator, .families = families, .arena = arena };
    }

    pub fn deinit(self: *FontCatalog) void {
        self.arena.deinit();
        self.families = &.{};
    }

    pub fn find(self: *const FontCatalog, name: []const u8) ?*const Family {
        for (self.families) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};

/// Whether saved font name can **really** parse back to same font.
///
/// Warning: must use it, can't just check if `coretext_find_font` returns non-null, that function
/// silently returns a substitute for missing families, so 'font missing' masquerades as 'font OK',
/// user sees different font with no hint.
pub fn familyExists(name: [:0]const u8) bool {
    if (builtin.target.os.tag != .macos) return false;
    return bridge.coretext_family_exists(name.ptr) != 0;
}

/// Max weight steps per family. Widest tested: Helvetica Neue 14 faces / 7 unique weights; variable
/// fonts at 100-900 max 9. 16 gives headroom.
pub const MAX_WEIGHTS: usize = 16;

/// Display names for standard weights (CSS value -> UI text). Unlike CoreText style names
/// (family-specific like 'Demi Bold'/'Heavy', where 600 varies by family), dropdown needs
/// consistent scale.
pub fn weightLabel(css: u16) []const u8 {
    return switch (css) {
        100 => "Thin",
        200 => "Extra Light",
        300 => "Light",
        400 => "Regular",
        500 => "Medium",
        600 => "Semibold",
        700 => "Bold",
        800 => "Extra Bold",
        900 => "Black",
        else => "Regular",
    };
}

/// **Actually available** weight steps in this family (CSS 100-900, ascending, deduplicated).
/// WARNING: generate the weight dropdown from this, not a fixed 100-900 list. CoreText silently
/// downgrades unavailable weights (Zapfino has one face, Bold returns Regular; Menlo + Light
/// returns
/// Regular), so offering them gives no failure signal. Non-macOS and families without an accessible
/// face default to a single 400; an empty list would make the dropdown un-clickable.
pub fn familyWeights(name: [:0]const u8, out: []u16) usize {
    if (out.len == 0) return 0;
    if (builtin.target.os.tag != .macos) {
        out[0] = 400;
        return 1;
    }
    var raw: [MAX_WEIGHTS]c_int = undefined;
    const cap: c_int = @intCast(@min(out.len, MAX_WEIGHTS));
    const n = bridge.coretext_family_weights(name.ptr, &raw, cap);
    if (n <= 0) {
        out[0] = 400;
        return 1;
    }
    var i: usize = 0;
    while (i < @as(usize, @intCast(n)) and i < out.len) : (i += 1) {
        out[i] = @intCast(@max(100, @min(900, raw[i])));
    }
    return i;
}

// tests.
// These assertions pin **machine-local measurement baselines** (see downstream app research docs).
// Swap machines with different fonts installed, numbers change, so assertions code structural
// invariants
// (every family has solution, symbol fonts nonzero...) not hardcoded 272/9/47.

test "CoreTextFamilyInfo 的 Zig 声明与 C 侧布局一致" {
    // Warning: struct shared across languages, field order/count must align exactly. Changed once:
    // added has_latin on Zig side, C-side patch didn't land (script assertion failed), compiled
    // anyway, but lang read misaligned bytes. This test pins size and key field offsets; any ABI
    // drift fails immediately.
    const I = bridge.CoreTextFamilyInfo;
    // 6 c_ints (is_symbolic/can_render_name/is_variable/face_count/classification/has_latin) +
    // char[16].
    try std.testing.expectEqual(@as(usize, 6 * @sizeOf(c_int) + 16), @sizeOf(I));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(I, "is_symbolic"));
    try std.testing.expectEqual(@as(usize, 6 * @sizeOf(c_int)), @offsetOf(I, "lang"));

    // Real call: lang must be valid UTF-8 and NUL-terminated inside (misalignment reads garbage).
    if (builtin.target.os.tag != .macos) return;
    var info: I = undefined;
    if (bridge.coretext_family_info("PingFang SC", &info) == 0) {
        const n = std.mem.indexOfScalar(u8, &info.lang, 0) orelse info.lang.len;
        try std.testing.expect(std.unicode.utf8ValidateSlice(info.lang[0..n]));
        try std.testing.expect(info.has_latin == 0 or info.has_latin == 1);
    }
}

test "catalog: 每个家族都能给出可渲染的预览内容" {
    // SKIP-REASON: depends on specific font families installed; minimal/CI images may not have them
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    var cat = try FontCatalog.scan(std.testing.allocator);
    defer cat.deinit();

    try std.testing.expect(cat.families.len > 0);

    for (cat.families) |fam| {
        switch (fam.previewPlan()) {
            .self => try std.testing.expect(fam.can_render_name and !fam.is_symbolic),
            // All three fallback paths must actually contain content; else that row is blank.
            .glyph_sample => |cps| try std.testing.expect(cps.len > 0),
            .lang_sample => |s| try std.testing.expect(s.len > 0),
            .codepoints => |cps| try std.testing.expect(cps.len > 0),
        }
    }
}

test "catalog: 符号字体走 glyph_sample 而不是 self" {
    // SKIP-REASON: depends on specific font families installed; minimal/CI images may not have them
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    var cat = try FontCatalog.scan(std.testing.allocator);
    defer cat.deinit();

    // Wingdings can_render_name empirically true (has 'A' glyph, but renders as picture); if
    // previewPlan order swapped, fails immediately. This test's reason for existence.
    if (cat.find("Wingdings")) |w| {
        try std.testing.expect(w.is_symbolic);
        try std.testing.expect(w.previewPlan() == .glyph_sample);
    }
}

test "catalog: 非拉丁字体不走 self" {
    // SKIP-REASON: depends on specific font families installed; minimal/CI images may not have them
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    var cat = try FontCatalog.scan(std.testing.allocator);
    defer cat.deinit();

    for ([_][]const u8{ "Geeza Pro", "Arial Hebrew" }) |n| {
        if (cat.find(n)) |f| {
            try std.testing.expect(!f.can_render_name);
            try std.testing.expect(f.previewPlan() != .self);
        }
    }
}

test "catalog: 列表里没有 face_count == 0 的死项" {
    // SKIP-REASON: depends on specific font families installed; minimal/CI images may not have them
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    var cat = try FontCatalog.scan(std.testing.allocator);
    defer cat.deinit();
    for (cat.families) |f| try std.testing.expect(f.face_count > 0);
    // SF Pro empirically: descriptor can't find face, must be filtered.
    try std.testing.expect(cat.find("SF Pro") == null);
}

test "familyExists: 不存在的家族不能伪装成存在" {
    // SKIP-REASON: depends on specific font families installed; minimal/CI images may not have them
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expect(familyExists("Helvetica Neue"));
    try std.testing.expect(!familyExists("NoSuchFontXYZ__"));
}

test "sampleForLang: 主子标签匹配" {
    try std.testing.expect(sampleForLang("zh-Hans") != null);
    try std.testing.expect(sampleForLang("ar") != null);
    try std.testing.expect(sampleForLang("") == null);
    try std.testing.expect(sampleForLang("xx-nonesuch") == null);
}

test "familyWeights: 每个家族至少一档，升序去重，落在 100~900" {
    // SKIP-REASON: depends on specific font families installed; minimal/CI images may not have them
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    var cat = try FontCatalog.scan(std.testing.allocator);
    defer cat.deinit();

    var buf: [MAX_WEIGHTS]u16 = undefined;
    var name_buf: [128]u8 = undefined;
    var checked: usize = 0;
    for (cat.families) |f| {
        if (f.name.len + 1 > name_buf.len) continue;
        @memcpy(name_buf[0..f.name.len], f.name);
        name_buf[f.name.len] = 0;
        const z: [:0]const u8 = name_buf[0..f.name.len :0];

        const n = familyWeights(z, &buf);
        // Empty list = dropdown un-clickable, must fall back to at least 400.
        try std.testing.expect(n >= 1);
        var prev: u16 = 0;
        for (buf[0..n]) |w| {
            try std.testing.expect(w >= 100 and w <= 900);
            try std.testing.expect(w > prev); // Ascending and strictly deduplicated
            prev = w;
        }
        checked += 1;
    }
    try std.testing.expect(checked > 0);
}

test "familyWeights: 单 face 家族只给一档（不谎报字体没有的字重）" {
    // SKIP-REASON: depends on specific font families installed; minimal/CI images may not have them
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    // Zapfino empirically: 1 face only. CoreText + Bold quietly returns Regular; dropdown must
    // never show Bold, test ensures 'no false claims'.
    // SKIP-REASON: depends on specific font families installed; minimal/CI images may not have them
    if (!familyExists("Zapfino")) return error.SkipZigTest;
    var buf: [MAX_WEIGHTS]u16 = undefined;
    const n = familyWeights("Zapfino", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u16, 400), buf[0]);
}

test "familyWeights: 多 face 家族给出多档且含 Regular/Bold" {
    // SKIP-REASON: depends on specific font families installed; minimal/CI images may not have them
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    // SKIP-REASON: depends on specific font families installed; minimal/CI images may not have them
    if (!familyExists("Helvetica Neue")) return error.SkipZigTest;
    var buf: [MAX_WEIGHTS]u16 = undefined;
    const n = familyWeights("Helvetica Neue", &buf);
    try std.testing.expect(n >= 4); // Empirically 7 weights
    var has400 = false;
    var has700 = false;
    for (buf[0..n]) |w| {
        if (w == 400) has400 = true;
        if (w == 700) has700 = true;
    }
    try std.testing.expect(has400);
    try std.testing.expect(has700);
}

test "weightLabel 覆盖全部标准档位" {
    try std.testing.expectEqualStrings("Regular", weightLabel(400));
    try std.testing.expectEqualStrings("Bold", weightLabel(700));
    try std.testing.expectEqualStrings("Black", weightLabel(900));
    // Non-standard values can't return empty string (UI would show blank line)
    try std.testing.expect(weightLabel(450).len > 0);
}
