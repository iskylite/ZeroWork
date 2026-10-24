//! font_fallback_stack.zig: explicit font fallback stack in CSS font-family style.
//!
//! Why: CJK glyphs relying on CoreText run-level fallback (unshapeable codepoints from an all-Latin
//! primary font like Inter/Lora cascade to system fonts) have three problems:
//!   1. The run-level fallback CTFontRef is unstable; cached by pointer, the same glyph counts as
//!      many new fonts, exhausting the atlas (see text_renderer.getOrCreateGlyphFallbackFont) and
//!      losing glyphs. Identity hashing fixes the key but the fallback itself is uncontrolled.
//!   2. The cascade choice is uncontrolled: the app hints PingFang SC, CoreText may give
//!      .AppleSystemUIFont.
//!   3. Every CJK glyph hits the slow path (run parsing + lookup); ASCII hits in one step.
//!
//! Semantics:
//! The app declares an ordered font family stack (e.g. [Inter, PingFang SC]). FontSelector's
//! primary is implicit first (coverage checking is TextRenderer.selectSegmentFont's job); this
//! manages the fallbacks after it. Before shaping, pick a family per segment's first codepoint:
//! the first family with cmap coverage wins, taking the closest font (size priority, then nearest
//! weight) among fonts we own with stable pointers, skipping cascade cost. Uncovered codepoints
//! (emoji, rare symbols) still cascade to CoreText.
//!
//! Per-OS default fallback:
//! defaultSystemFamilyName() gives the platform default CJK family (macOS = PingFang SC,
//! Windows = Microsoft YaHei UI). The app loads fonts (it knows FontManager + sizes); this only
//! provides the platform choice.
//!
//! Script priority:
//! Pure coverage-first selection falls into traps like 'PingFang also covers some Hangul': Korean
//! text must prefer Hangul fonts (Hangul glyph style differs from Chinese fonts).
//! A family declares priority (hangul/han_kana); script-matching codepoints try priority families
//! first, then pure coverage in stack order, aligned with script_detect.

const std = @import("std");
const builtin = @import("builtin");
const text_module = @import("text");
const Font = text_module.Font;

/// Default system CJK fallback family name. Windows YaHei UI verified on Win11 ARM.
/// null = platform undefined yet; app decides or defers to platform cascade.
pub fn defaultSystemFamilyName() ?[]const u8 {
    return switch (builtin.os.tag) {
        .macos => "PingFang SC",
        .windows => "Microsoft YaHei UI",
        else => null,
    };
}

/// Codepoint script classes: only three needing different fallback strategy. Ranges
/// aligned with command_encoder/script_detect.zig (that answers per-segment fallback?,
/// this answers per-codepoint which family type?).
pub const ScriptClass = enum { hangul, han_kana, other };

pub fn classifyCodepoint(cp: u21) ScriptClass {
    // Hangul priority: 3130-318F (Compatibility Jamo) at edge of han_kana range below,
    // must intercept first.
    if ((cp >= 0x1100 and cp <= 0x11FF) or // Hangul Jamo
        (cp >= 0x3130 and cp <= 0x318F) or // Hangul Compatibility Jamo
        (cp >= 0xAC00 and cp <= 0xD7AF)) return .hangul; // Hangul Syllables
    if ((cp >= 0x2E80 and cp <= 0x2FDF) or // CJK/Kangxi Radicals
        (cp >= 0x3000 and cp <= 0x312F) or // CJK Symbols + Kana + Bopomofo
        (cp >= 0x31A0 and cp <= 0x33FF) or // Bopomofo Ext + Kana Ext + Enclosed + Compat
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK Ext A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK Unified Ideographs
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK Compatibility Ideographs
        (cp >= 0xFE30 and cp <= 0xFE4F) or // CJK Compatibility Forms
        (cp >= 0xFF00 and cp <= 0xFFEF) or // Halfwidth and Fullwidth Forms
        (cp >= 0x20000 and cp <= 0x2FA1F)) return .han_kana; // Ext B..Compat Supplement
    return .other;
}

/// Fixed-weight-tier font weight mapping: 400->Regular, 500->Medium, 600+->Semibold.
/// (Variable fonts like Inter unused; FontSelector loads exact weight.)
pub fn archiveWeight(weight: u16) u16 {
    return if (weight >= 600) 600 else if (weight >= 500) 500 else 400;
}

pub const FontFallbackStack = struct {
    pub const MAX_FAMILIES = 4;
    pub const MAX_FONTS_PER_FAMILY = 40;
    /// Coverage cache capacity limit. Codepoint space limited (typical doc charset few
    /// thousand); overflow only from malicious input; flush+restart, no eviction.
    const COVERAGE_CACHE_MAX = 16384;

    pub const Priority = enum { none, han_kana, hangul };

    pub const Family = struct {
        /// Family name (diagnostic only; unused at runtime). Pointed memory must outlive stack
        /// (string constant OK).
        name: []const u8,
        priority: Priority = .none,
        /// Loaded size/weight tiers for this family. *Font owned by app; this struct borrows.
        fonts: [MAX_FONTS_PER_FAMILY]?*Font = @as([MAX_FONTS_PER_FAMILY]?*Font, @splat(null)),
        count: u8 = 0,
    };

    families: [MAX_FAMILIES]Family = undefined,
    family_count: u8 = 0,
    /// codepoint -> matched family index + 1; 0 = no family in stack covers (cascade fallback).
    /// cmap coverage independent of size/weight; key is codepoint only.
    coverage_cache: std.AutoHashMap(u21, u8),

    pub fn init(allocator: std.mem.Allocator) FontFallbackStack {
        return .{ .coverage_cache = std.AutoHashMap(u21, u8).init(allocator) };
    }

    /// Frees only own cache; *Font owned by app, not deinit.
    pub fn deinit(self: *FontFallbackStack) void {
        self.coverage_cache.deinit();
    }

    /// Append family to stack end. Returns family index; null if full.
    pub fn addFamily(self: *FontFallbackStack, name: []const u8, priority: Priority) ?u8 {
        if (self.family_count >= MAX_FAMILIES) return null;
        const idx = self.family_count;
        self.families[idx] = .{ .name = name, .priority = priority };
        self.family_count = idx + 1;
        // Family set change = coverage answers may change.
        self.coverage_cache.clearRetainingCapacity();
        return idx;
    }

    /// Append loaded weight tier to family (same as font_compat.addToGroup: full = silent
    /// drop, selection finds nearest existing).
    pub fn addFont(self: *FontFallbackStack, family_idx: u8, font: *Font) void {
        if (family_idx >= self.family_count) return;
        const fam = &self.families[family_idx];
        if (fam.count >= MAX_FONTS_PER_FAMILY) return;
        fam.fonts[fam.count] = font;
        fam.count += 1;
        // An empty family may already have been queried. Its first font changes
        // coverage and can supersede another family's cached script match.
        // Further size/weight slots leave the first-font cmap probe unchanged.
        if (fam.count == 1) self.coverage_cache.clearRetainingCapacity();
    }

    /// Explicit font selection: codepoint -> family covering it (script priority + stack
    /// order) -> nearest tier. null = no family covers, caller defers to CoreText cascade.
    pub fn selectForCodepoint(self: *FontFallbackStack, cp: u21, size: f32, weight: u16) ?*Font {
        const fam_idx = self.familyForCodepoint(cp) orelse return null;
        return selectFromFamily(&self.families[fam_idx], size, weight);
    }

    fn familyForCodepoint(self: *FontFallbackStack, cp: u21) ?u8 {
        if (self.family_count == 0) return null;
        if (self.coverage_cache.get(cp)) |v| {
            return if (v == 0) null else v - 1;
        }
        var chosen: u8 = 0;
        const cls = classifyCodepoint(cp);
        found: {
            // Pass 1: script's priority families (Hangul codepoint queries Hangul first even if CJK
            // covers).
            if (cls != .other) {
                const want: Priority = if (cls == .hangul) .hangul else .han_kana;
                for (self.families[0..self.family_count], 0..) |*fam, i| {
                    if (fam.priority == want and familyCovers(fam, cp)) {
                        chosen = @as(u8, @intCast(i)) + 1;
                        break :found;
                    }
                }
            }
            // Pass 2: pure coverage by stack order.
            for (self.families[0..self.family_count], 0..) |*fam, i| {
                if (familyCovers(fam, cp)) {
                    chosen = @as(u8, @intCast(i)) + 1;
                    break :found;
                }
            }
        }
        if (self.coverage_cache.count() >= COVERAGE_CACHE_MAX) {
            self.coverage_cache.clearRetainingCapacity();
        }
        self.coverage_cache.put(cp, chosen) catch {};
        return if (chosen == 0) null else chosen - 1;
    }

    fn familyCovers(fam: *const Family, cp: u21) bool {
        // cmap independent of size: probe first tier.
        const probe = fam.fonts[0] orelse return false;
        return probe.glyphIndexForCodepoint(cp) != 0;
    }

    /// Pick tier in family: size priority first (per FontSelector.selectFromGroup: app may use
    /// different weights at sizes, e.g. 14px body Medium for CJK brightness; weight-first breaks
    /// this), when sizes tied pick closest to target weight; when weight tiers tied, bold requests
    /// (>=600) pick heavier, else lighter (simplified CSS font-weight matching).
    fn selectFromFamily(fam: *const Family, size: f32, weight: u16) ?*Font {
        const size_epsilon: f32 = 0.01;
        const target_w = archiveWeight(weight);
        var best: ?*Font = null;
        var best_size_diff: f32 = std.math.inf(f32);
        var best_w_diff: u16 = std.math.maxInt(u16);
        for (fam.fonts[0..fam.count]) |maybe_font| {
            const font = maybe_font orelse continue;
            const size_diff = @abs(font.pixelSize() - size);
            const w_diff = if (font.weight >= target_w) font.weight - target_w else target_w - font.weight;
            const better = blk: {
                if (best == null) break :blk true;
                if (size_diff + size_epsilon < best_size_diff) break :blk true;
                if (size_diff > best_size_diff + size_epsilon) break :blk false;
                if (w_diff != best_w_diff) break :blk w_diff < best_w_diff;
                const b = best.?;
                break :blk if (target_w >= 600) font.weight > b.weight else font.weight < b.weight;
            };
            if (better) {
                best = font;
                best_size_diff = size_diff;
                best_w_diff = w_diff;
            }
        }
        return best;
    }
};

// ── Unit tests ────────────────────────────────────────────
const testing = std.testing;

fn dummyFont(size: f32, weight: u16) Font {
    return .{
        .allocator = undefined,
        .ct_font = undefined,
        .io = std.testing.io,
        .size = @intFromFloat(size),
        .size_px = size,
        .weight = weight,
    };
}

test "archiveWeight: 固定档最近映射 400/500/600+" {
    try testing.expectEqual(@as(u16, 400), archiveWeight(100));
    try testing.expectEqual(@as(u16, 400), archiveWeight(400));
    try testing.expectEqual(@as(u16, 400), archiveWeight(450));
    try testing.expectEqual(@as(u16, 500), archiveWeight(500));
    try testing.expectEqual(@as(u16, 500), archiveWeight(550));
    try testing.expectEqual(@as(u16, 600), archiveWeight(600));
    try testing.expectEqual(@as(u16, 600), archiveWeight(700));
    try testing.expectEqual(@as(u16, 600), archiveWeight(900));
}

test "classifyCodepoint: 汉字/假名/谚文/其他" {
    try testing.expectEqual(ScriptClass.han_kana, classifyCodepoint(0x4E2D)); // CJK character
    try testing.expectEqual(ScriptClass.han_kana, classifyCodepoint(0x3042)); // あ
    try testing.expectEqual(ScriptClass.han_kana, classifyCodepoint(0x30A2)); // ア
    try testing.expectEqual(ScriptClass.hangul, classifyCodepoint(0xAC00)); // 가
    try testing.expectEqual(ScriptClass.hangul, classifyCodepoint(0x3131)); // ㄱ (compat jamo)
    try testing.expectEqual(ScriptClass.other, classifyCodepoint('A'));
    try testing.expectEqual(ScriptClass.other, classifyCodepoint(0x1F600)); // 😀
    try testing.expectEqual(ScriptClass.other, classifyCodepoint(0x05D0)); // א
}

test "selectFromFamily: 字号优先，档内字重最近，粗体请求并列取更粗" {
    var f14m = dummyFont(14, 500); // 14px tier intentionally Medium (app brightness design)
    var f14b = dummyFont(14, 700);
    var f16r = dummyFont(16, 400);
    var f16m = dummyFont(16, 500);
    var f16b = dummyFont(16, 700);

    var stack = FontFallbackStack.init(testing.allocator);
    defer stack.deinit();
    const fi = stack.addFamily("Test CJK", .han_kana).?;
    for ([_]*Font{ &f14m, &f14b, &f16r, &f16m, &f16b }) |f| stack.addFont(fi, f);
    const fam = &stack.families[fi];

    // 450@14 -> nearest to weight 400 in 14px tier is Medium (size priority, don't cross to
    // other sizes)
    try testing.expectEqual(@as(?*Font, &f14m), FontFallbackStack.selectFromFamily(fam, 14, 450));
    // 400@16 -> Regular
    try testing.expectEqual(@as(?*Font, &f16r), FontFallbackStack.selectFromFamily(fam, 16, 400));
    // 500@16 -> Medium
    try testing.expectEqual(@as(?*Font, &f16m), FontFallbackStack.selectFromFamily(fam, 16, 500));
    // 620@16 -> target tier 600, weight tiers 500/700 tied -> bold request picks heavier
    // (real Semibold face)
    try testing.expectEqual(@as(?*Font, &f16b), FontFallbackStack.selectFromFamily(fam, 16, 620));
    // 700@15 -> no 15px tier, sizes 14/16 tied so pick by weight distance (both have 700) ->
    // first 14px bold
    try testing.expectEqual(@as(?*Font, &f14b), FontFallbackStack.selectFromFamily(fam, 15, 700));
}

test "defaultSystemFamilyName: macOS = PingFang SC" {
    if (builtin.os.tag == .macos) {
        try testing.expectEqualStrings("PingFang SC", defaultSystemFamilyName().?);
    }
}

test "familyForCodepoint: 真实系统字体的覆盖与脚本优先（macOS）" {
    // SKIP-REASON: depends on specific font families installed locally; minimal/CI images
    // may lack them
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fs = try text_module.FontSystem.init(testing.allocator, @import("std").testing.io);
    defer fs.deinit();
    // SKIP-REASON: depends on specific font families installed locally; minimal/CI images
    // may lack them
    const pf = fs.findFont(.{ .family = "PingFang SC", .size = 14, .weight = .regular, .style = .normal }) catch return error.SkipZigTest;
    defer pf.deinit();
    // SKIP-REASON: depends on specific font families installed locally; minimal/CI images
    // may lack them
    const gothic = fs.findFont(.{ .family = "Apple SD Gothic Neo", .size = 14, .weight = .regular, .style = .normal }) catch return error.SkipZigTest;
    defer gothic.deinit();

    var stack = FontFallbackStack.init(testing.allocator);
    defer stack.deinit();
    const ci = stack.addFamily("PingFang SC", .han_kana).?;
    stack.addFont(ci, pf);
    const ki = stack.addFamily("Apple SD Gothic Neo", .hangul).?;
    stack.addFont(ki, gothic);

    // CJK -> PingFang (pass 1 script priority match)
    try testing.expectEqual(@as(?*Font, pf), stack.selectForCodepoint(0x4E2D, 14, 400));
    // Hangul -> Gothic: even if PingFang earlier in stack and covers, use hangul priority
    try testing.expectEqual(@as(?*Font, gothic), stack.selectForCodepoint(0xAC00, 14, 400));
    // emoji -> neither family covers -> null (cascade fallback)
    try testing.expectEqual(@as(?*Font, null), stack.selectForCodepoint(0x1F600, 14, 400));
    // Second query hits coverage cache, answer must match
    try testing.expectEqual(@as(?*Font, pf), stack.selectForCodepoint(0x4E2D, 14, 400));
}
