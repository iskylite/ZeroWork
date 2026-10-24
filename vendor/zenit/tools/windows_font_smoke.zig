fn checkFallbackStack(fonts: *text.FontSystem) !void {
    const fallback = @import("font_fallback_stack");
    const system_family = fallback.defaultSystemFamilyName() orelse return error.MissingWindowsCjkFamily;
    if (!std.mem.eql(u8, system_family, "Microsoft YaHei UI")) return error.IncorrectWindowsCjkFamily;
    const japanese = try fonts.findFont(.{ .family = "Yu Gothic UI", .size = 16 });
    defer japanese.deinit();
    const chinese = try fonts.findFont(.{ .family = system_family, .size = 16 });
    defer chinese.deinit();
    const chinese_bold = try fonts.findFont(.{ .family = system_family, .size = 24, .weight = .bold });
    defer chinese_bold.deinit();
    const korean = try fonts.findFont(.{ .family = "Malgun Gothic", .size = 16 });
    defer korean.deinit();
    const emoji = try fonts.findFont(.{ .family = "Segoe UI Emoji", .size = 16 });
    defer emoji.deinit();
    var stack = fallback.FontFallbackStack.init(std.heap.page_allocator);
    defer stack.deinit();
    if (stack.selectForCodepoint('W', 16, 400) != null) return error.NonemptyInitialFallbackStack;
    const general = stack.addFamily("general", .none) orelse return error.FallbackStackFull;
    stack.addFont(general, japanese);
    // This answer was negatively cached before adding the first family.
    if (stack.selectForCodepoint('W', 16, 400) != japanese) return error.StaleFallbackCoverageCache;
    if (japanese.glyphIndexForCodepoint('中') == 0 or chinese.glyphIndexForCodepoint('中') == 0) return error.MissingChineseCoverage;
    if (stack.selectForCodepoint('中', 16, 400) != japanese) return error.IncorrectStackOrder;
    const han = stack.addFamily("Chinese priority", .han_kana) orelse return error.FallbackStackFull;
    stack.addFont(han, chinese);
    stack.addFont(han, chinese_bold);
    if (stack.selectForCodepoint('中', 16, 700) != chinese or
        stack.selectForCodepoint('中', 24, 400) != chinese_bold or
        stack.selectForCodepoint('中', 20, 400) != chinese or
        stack.selectForCodepoint('中', 20, 700) != chinese_bold) return error.IncorrectFallbackSizeWeightPriority;
    const hangul = stack.addFamily("Korean priority", .hangul) orelse return error.FallbackStackFull;
    _ = stack.selectForCodepoint('한', 16, 400); // Lookup before this family is populated.
    stack.addFont(hangul, korean);
    if (korean.glyphIndexForCodepoint('한') == 0 or stack.selectForCodepoint('한', 16, 400) != korean) return error.IncorrectHangulPriority;
    const symbols = stack.addFamily("Emoji", .none) orelse return error.FallbackStackFull;
    stack.addFont(symbols, emoji);
    if (emoji.glyphIndexForCodepoint(0x1f600) == 0 or stack.selectForCodepoint(0x1f600, 16, 400) == null or
        stack.selectForCodepoint(0x10ffff, 16, 400) != null) return error.IncorrectFallbackCoverage;
    if (stack.addFamily("overflow", .none) != null) return error.AcceptedFallbackOverflow;
    std.debug.print("Windows fallback stack: system YaHei UI, native cmap, stack order, script priority, size/weight ties, negative-cache invalidation and missing coverage PASS\n", .{});
}

extern fn zenit_dwrite_font_identity(font: *anyopaque) u64;
const std = @import("std");
const text = @import("text");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var fonts = try text.FontSystem.init(allocator, init.io);
    defer fonts.deinit();
    var probe_shaper = try text.TextShaper.init(allocator);
    defer probe_shaper.deinit();
    for ([_]text.FontWeight{ .regular, .medium, .semibold, .bold, .black }) |weight| {
        const face = try fonts.findFont(.{ .family = "system", .size = 16, .weight = weight });
        defer face.deinit();
        const name = face.debugName(allocator) orelse return error.MissingFontDebugName;
        defer allocator.free(name);
        std.debug.print("mixed UI requested={s}: {s}\n", .{ @tagName(weight), name });
        const shaped = try probe_shaper.shape("卡片 → 右上（主实例）双实例 Two notifiers", face);
        defer allocator.free(shaped);
        var previous: u64 = 0;
        for (shaped) |glyph| if (glyph.fallback_font_ref) |ref| {
            defer text.releaseFallbackFontRef(ref);
            const identity = text.fallbackFontRefIdentityHash(ref);
            if (identity == previous) continue;
            previous = identity;
            const fallback_name = text.fallbackFontRefDebugName(allocator, ref) orelse return error.MissingFallbackDebugName;
            defer allocator.free(fallback_name);
            std.debug.print("  cluster={d}: {s}\n", .{ glyph.cluster, fallback_name });
        };
    }
    fonts.setDefaultLocale("zh-CN");
    try checkFallbackStack(&fonts);
    try checkColorGlyphs(&fonts);
    try @import("windows_font_ranges_contract.zig").run(&fonts);
    for ([_]text.FontWeight{ .regular, .medium, .semibold, .bold }) |weight| {
        const chinese = try fonts.findFont(.{ .family = "system", .size = 16, .weight = weight });
        defer chinese.deinit();
        const resized = try chinese.derive(20);
        defer resized.deinit();
        for ([_]*text.Font{ chinese, resized }) |face| {
            const chinese_glyphs = try probe_shaper.shape("卡片右上主实例双实例", face);
            defer {
                for (chinese_glyphs) |glyph| if (glyph.fallback_font_ref) |ref| text.releaseFallbackFontRef(ref);
                allocator.free(chinese_glyphs);
            }
            if (chinese_glyphs.len != 10) return error.MissingChineseGlyphs;
            var previous: ?u64 = null;
            for (chinese_glyphs) |glyph| {
                const ref = glyph.fallback_font_ref orelse return error.MissingChineseFallback;
                const identity = text.fallbackFontRefIdentityHash(ref);
                if (previous) |expected| {
                    if (identity != expected) return error.InconsistentChineseFace;
                }
                previous = identity;
                const name = text.fallbackFontRefDebugName(allocator, ref) orelse return error.MissingFallbackDebugName;
                defer allocator.free(name);
                if (!std.mem.startsWith(u8, name, "DirectWrite Microsoft YaHei UI weight=")) return error.IncorrectChineseLocaleFallback;
                if (glyph.cluster == 0) std.debug.print("zh-CN requested={s} size={d}: {s}\n", .{ @tagName(weight), face.pixelSize(), name });
            }
        }
    }
    const font = try fonts.findFont(.{ .family = "system", .size = 16 });
    defer font.deinit();
    try checkFileFonts(allocator, &fonts, font, &probe_shaper);
    // A shaped fallback owns a face but has no text format. The shared text
    // renderer must materialize an independent Font that survives the shape.
    const owned_fallback = blk: {
        const shaped = try probe_shaper.shape("中", font);
        defer {
            for (shaped) |glyph| if (glyph.fallback_font_ref) |ref| text.releaseFallbackFontRef(ref);
            allocator.free(shaped);
        }
        const ref = shaped[0].fallback_font_ref orelse return error.MissingChineseFallback;
        const wrapped = try text.Font.fromFallbackRef(allocator, ref, font);
        errdefer wrapped.deinit();
        if (text.fallbackFontRefIdentityHash(wrapped.native) != text.fallbackFontRefIdentityHash(ref))
            return error.FallbackWrapperChangedFace;
        if (!std.ascii.eqlIgnoreCase(wrapped.locale, font.locale)) return error.FallbackWrapperChangedLocale;
        break :blk wrapped;
    };
    defer owned_fallback.deinit();
    const owned_derived = try owned_fallback.derive(24);
    defer owned_derived.deinit();
    var owned_bitmap = try owned_fallback.rasterizeGlyph(owned_fallback.glyphIndexForCodepoint('中'));
    defer owned_bitmap.deinit(allocator);
    const owned_width = owned_fallback.measureWidth("中文");
    if (owned_bitmap.width == 0 or !(owned_width > 0) or
        @abs(owned_derived.measureWidth("中文") / owned_width - 1.5) > 0.01)
        return error.FallbackWrapperLifetimeOrDerivation;
    std.debug.print("owned native fallback: released shape, preserved face/locale, raster and derive PASS\n", .{});
    const sample = "Zenit Windows ARM64";
    const derived = try font.derive(20);
    defer derived.deinit();
    var shaper = try text.TextShaper.init(allocator);
    defer shaper.deinit();
    const glyphs = try shaper.shape(sample, font);
    defer {
        for (glyphs) |glyph| if (glyph.fallback_font_ref) |ref| text.releaseFallbackFontRef(ref);
        allocator.free(glyphs);
    }
    var bitmap = try font.rasterizeGlyph(font.glyphIndexForCodepoint('Z'));
    defer bitmap.deinit(allocator);
    const boundaries = [_]u32{ 0, 1, 5, sample.len };
    var stops: [boundaries.len]text.LineCaretStop = undefined;
    const line = try font.lineCaretStops(sample, &boundaries, &stops);
    if (!(line.width > 0) or !(font.getAscent() > 0) or glyphs.len == 0 or
        bitmap.width == 0 or bitmap.height == 0 or derived.pixelSize() != 20)
        return error.InvalidFontMetrics;
    const arabic_text = "مرحبا";
    const arabic_boundaries = [_]u32{ 0, 2, 4, 6, 8, 10 };
    var arabic_stops: [arabic_boundaries.len]text.LineCaretStop = undefined;
    const arabic_line = try font.lineCaretStops(arabic_text, &arabic_boundaries, &arabic_stops);
    if (@abs(arabic_stops[0].primary_x - arabic_line.width) > 0.1 or @abs(arabic_stops[5].primary_x) > 0.1) return error.InvalidRtlCaretEdges;
    for (arabic_stops[1..], arabic_stops[0 .. arabic_stops.len - 1]) |next, previous| {
        if (next.primary_x > previous.primary_x + 0.1) return error.RtlCaretNotDecreasing;
    }
    const mixed = "abc مرحبا xyz";
    const mixed_boundaries = [_]u32{ 0, 4, 14, mixed.len };
    var mixed_stops: [mixed_boundaries.len]text.LineCaretStop = undefined;
    _ = try font.lineCaretStops(mixed, &mixed_boundaries, &mixed_stops);
    if (!mixed_stops[1].has_secondary or !mixed_stops[2].has_secondary) return error.MissingBidiSecondaryCarets;
    const cluster_text = "e\u{301}👨‍👩‍👧‍👦";
    const cluster_boundaries = [_]u32{ 0, 3, cluster_text.len };
    var cluster_stops: [cluster_boundaries.len]text.LineCaretStop = undefined;
    const cluster_line = try font.lineCaretStops(cluster_text, &cluster_boundaries, &cluster_stops);
    if (@abs(cluster_stops[2].primary_x - cluster_line.width) > 0.1) return error.InvalidEmojiCaretEdge;
    const invalid = [_]u32{1};
    var invalid_stop: [1]text.LineCaretStop = undefined;
    if (font.lineCaretStops(arabic_text, &invalid, &invalid_stop)) |_| {
        return error.AcceptedInvalidUtf8Boundary;
    } else |err| {
        if (err != error.TextCaretExtractionFailed) return err;
    }
    const empty_boundaries = [_]u32{0};
    var empty_stop: [1]text.LineCaretStop = undefined;
    const empty_line = try font.lineCaretStops("", &empty_boundaries, &empty_stop);
    if (empty_line.width != 0 or empty_stop[0].primary_x != 0) return error.InvalidEmptyCaret;
    std.debug.print("caret Arabic start={d:.2} end={d:.2}; mixed secondary={}/{}; emoji end={d:.2}\n", .{ arabic_stops[0].primary_x, arabic_stops[5].primary_x, mixed_stops[1].has_secondary, mixed_stops[2].has_secondary, cluster_stops[2].primary_x });
    const samples = [_][]const u8{ "مرحبا", "بببب", "ب\u{200c}ب\u{200c}ب\u{200c}ب", "e\u{301}", "👨‍👩‍👧‍👦", "中文" };
    for (samples, 0..) |value, sample_index| {
        const shaped = try shaper.shape(value, font);
        defer {
            for (shaped) |glyph| if (glyph.fallback_font_ref) |ref| text.releaseFallbackFontRef(ref);
            allocator.free(shaped);
        }
        if (shaped.len == 0) return error.MissingShapedGlyphs;
        var advance: f32 = 0;
        var fallbacks: usize = 0;
        for (shaped) |glyph| {
            if (glyph.cluster >= value.len or (value[glyph.cluster] & 0xc0) == 0x80) return error.InvalidUtf8Cluster;
            if (!std.math.isFinite(glyph.x_advance) or !std.math.isFinite(glyph.x_offset)) return error.InvalidGlyphPosition;
            advance += glyph.x_advance;
            if (glyph.fallback_font_ref) |ref| {
                fallbacks += 1;
                if (!(text.fallbackFontRefSize(ref) > 0)) return error.InvalidFallbackSize;
                text.retainFallbackFontRef(ref);
                text.releaseFallbackFontRef(ref);
            }
        }
        if (@abs(advance - font.measureWidth(value)) > 0.1) return error.ShapeMeasureMismatch;
        if (sample_index == 0 and shaped[0].cluster <= shaped[shaped.len - 1].cluster) return error.ArabicNotInVisualOrder;
        if (sample_index == 1) {
            var changed_form = false;
            for (shaped) |glyph| if (glyph.glyph_index != font.glyphIndexForCodepoint(0x628)) {
                changed_form = true;
            };
            if (!changed_form) return error.ArabicNotJoined;
        }
        if (sample_index == 3) {
            for (shaped) |glyph| if (glyph.cluster != 0) return error.CombiningMarkSplitCluster;
        }
        if (sample_index == 4) {
            for (shaped) |glyph| std.debug.print("emoji glyph={d} cluster={d} fallback={}\n", .{ glyph.glyph_index, glyph.cluster, glyph.is_fallback_font });
            // DirectWrite may decompose one color glyph into multiple runs.
            // The contract is one UTF-8 cluster, not one physical glyph.
            for (shaped) |glyph| if (glyph.cluster != 0) return error.FamilyEmojiNotShapedAsCluster;
            if (fallbacks == 0) return error.MissingEmojiFallback;
        }
        if (sample_index == 5) {
            for (shaped) |glyph| if (glyph.glyph_index == 0) return error.MissingCjkGlyph;
            if (fallbacks == 0) return error.MissingCjkFallback;
        }
        std.debug.print("shape sample={s} glyphs={d} advance={d:.2} fallback={d}\n", .{ value, shaped.len, advance, fallbacks });
    }
    const repeat_text = "中文 👨‍👩‍👧‍👦";
    const first = try shaper.shape(repeat_text, font);
    defer {
        for (first) |glyph| if (glyph.fallback_font_ref) |ref| text.releaseFallbackFontRef(ref);
        allocator.free(first);
    }
    const second = try shaper.shape(repeat_text, font);
    defer {
        for (second) |glyph| if (glyph.fallback_font_ref) |ref| text.releaseFallbackFontRef(ref);
        allocator.free(second);
    }
    if (first.len != second.len) return error.UnstableShaping;
    for (first, second) |one, two| {
        if (one.fallback_font_ref) |ref| {
            const again = two.fallback_font_ref orelse return error.MissingRepeatedFallback;
            if (text.fallbackFontRefIdentityHash(ref) != text.fallbackFontRefIdentityHash(again)) return error.UnstableFallbackIdentity;
        }
    }
    std.debug.print("fallback identity stable across repeated CJK/emoji shaping\n", .{});
    std.debug.print("DirectWrite width={d:.2} ascent={d:.2} glyphs={d}\n", .{ line.width, font.getAscent(), glyphs.len });
}

fn checkFileFonts(allocator: std.mem.Allocator, fonts: *text.FontSystem, system_font: *text.Font, shaper: *text.TextShaper) !void {
    const temp = try @import("zenit_environment").getOwned(allocator, "TEMP");
    defer allocator.free(temp);
    var random_bytes: [8]u8 = undefined;
    fonts.io.random(&random_bytes);
    const directory = try std.fmt.allocPrint(allocator, "{s}\\zenit-font-probe-{x}", .{ temp, std.mem.readInt(u64, &random_bytes, .little) });
    defer allocator.free(directory);
    try std.Io.Dir.cwd().createDir(fonts.io, directory, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(fonts.io, directory) catch {};
    const fixtures = .{
        .{ "字体 Regular.ttf", @embedFile("fixtures/fonts/Lora-Regular.ttf"), @as(u16, 400), false },
        .{ "字体 BoldItalic.ttf", @embedFile("fixtures/fonts/Lora-BoldItalic.ttf"), @as(u16, 700), true },
    };
    inline for (fixtures) |fixture| {
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}\\{s}", .{ directory, fixture[0] }, 0);
        defer allocator.free(path);
        try std.Io.Dir.cwd().writeFile(fonts.io, .{ .sub_path = path, .data = fixture[1] });
        if (fonts.loadFont(path, 0)) |unexpected| {
            unexpected.deinit();
            return error.AcceptedZeroFontSize;
        } else |err| {
            if (err != error.FontLoadFailed) return err;
        }
        for (0..3) |_| {
            const loaded = try fonts.loadFont(path, 16);
            var loaded_alive = true;
            defer if (loaded_alive) loaded.deinit();
            if (!std.mem.eql(u8, loaded.family, "Lora") or loaded.weight != fixture[2] or loaded.italic != fixture[3]) return error.IncorrectFileFontMetadata;
            try @import("windows_font_ranges_contract.zig").checkPrivate(system_font, loaded);
            loaded.setScaleFactor(1.75);
            const identity = text.fallbackFontRefIdentityHash(loaded.native);
            const resized = try loaded.derive(24);
            defer resized.deinit();
            if (resized.scale_factor != 1.75 or resized.pixelSize() != 24 or zenit_dwrite_font_identity(resized.native) != zenit_dwrite_font_identity(loaded.native)) return error.FileFontDeriveChangedFace;
            const sample = "AV ffi Windows";
            const width = loaded.measureWidth(sample);
            if (!(width > 0) or @abs(width - system_font.measureWidth(sample)) < 1) return error.FileFontMeasurementUsedSystem;
            const glyphs = try shaper.shape(sample, loaded);
            defer {
                for (glyphs) |glyph| if (glyph.fallback_font_ref) |ref| text.releaseFallbackFontRef(ref);
                allocator.free(glyphs);
            }
            for (glyphs) |glyph| if (glyph.fallback_font_ref) |ref| {
                if (text.fallbackFontRefIdentityHash(ref) != identity) return error.FileFontShapeUsedSystem;
            };
            // Derived fonts must keep the private collection alive after the parent dies.
            loaded.deinit();
            loaded_alive = false;
            var bitmap = try resized.rasterizeGlyph(resized.glyphIndexForCodepoint('A'));
            defer bitmap.deinit(allocator);
            if (bitmap.width == 0 or bitmap.height == 0) return error.FileFontRasterEmpty;
            var ink: usize = 0;
            for (bitmap.pixels) |pixel| {
                if (pixel > 0) ink += 1;
            }
            if (ink < 20) return error.FileFontRasterHasNoInk;
            const derived_width = resized.measureWidth(sample);
            if (@abs(derived_width / width - 1.5) > 0.01) return error.FileFontDerivedMeasurementMismatch;
            const name = resized.debugName(allocator) orelse return error.MissingFontDebugName;
            defer allocator.free(name);
            std.debug.print("private font {s}: width16={d:.2} width24={d:.2} raster={d}x{d}\n", .{ name, width, derived_width, bitmap.width, bitmap.height });
        }
    }
    const invalid = try std.fmt.allocPrintSentinel(allocator, "{s}\\invalid.ttf", .{directory}, 0);
    defer allocator.free(invalid);
    if (fonts.loadFont(invalid, 16)) |unexpected| {
        unexpected.deinit();
        return error.AcceptedMissingFontFile;
    } else |err| {
        if (err != error.FontLoadFailed) return err;
    }
    try std.Io.Dir.cwd().writeFile(fonts.io, .{ .sub_path = invalid, .data = "not a font" });
    if (fonts.loadFont(invalid, 16)) |unexpected| {
        unexpected.deinit();
        return error.AcceptedMalformedFontFile;
    } else |err| {
        if (err != error.FontLoadFailed) return err;
    }
    if (fonts.loadFont(invalid, 0)) |unexpected| {
        unexpected.deinit();
        return error.AcceptedZeroFontSize;
    } else |err| {
        if (err != error.FontLoadFailed) return err;
    }
}

fn checkColorGlyphs(fonts: *text.FontSystem) !void {
    const emoji = try fonts.findFont(.{ .family = "Segoe UI Emoji", .size = 48 });
    defer emoji.deinit();
    const plain = try fonts.findFont(.{ .family = "Segoe UI", .size = 48 });
    defer plain.deinit();
    if (!emoji.hasColorGlyphs() or plain.hasColorGlyphs()) return error.IncorrectColorFontCapability;
    for ([_]f32{ 1, 1.75, 2 }) |scale| {
        emoji.setScaleFactor(scale);
        for ([_]u32{ 0x1f7e5, 0x1f7e9, 0x1f7e6, 0x1f600 }, 0..) |codepoint, index| {
            const glyph = emoji.glyphIndexForCodepoint(codepoint);
            if (glyph == 0) return error.MissingColorGlyph;
            const bitmap = try emoji.rasterizeGlyphSubpixel(glyph, 0.25, 0.25);
            defer bitmap.deinit(std.heap.page_allocator);
            if (!bitmap.is_color or bitmap.width == 0 or bitmap.height == 0 or bitmap.pixels.len != bitmap.width * bitmap.height * 4) return error.MissingColorBitmap;
            var colored: usize = 0;
            var antialiased: usize = 0;
            for (0..bitmap.width * bitmap.height) |i| {
                const px = bitmap.pixels[i * 4 ..][0..4];
                if (px[0] > px[3] or px[1] > px[3] or px[2] > px[3]) return error.NonPremultipliedColorBitmap;
                if (px[3] > 0 and px[3] < 255) antialiased += 1;
                if (@max(px[0], @max(px[1], px[2])) - @min(px[0], @min(px[1], px[2])) > 40) colored += 1;
            }
            if (colored < 100 or antialiased == 0) return error.ColorBitmapMissingCoverage;
            if (index < 3) {
                const p = ((bitmap.height / 2) * bitmap.width + bitmap.width / 2) * 4;
                const center = bitmap.pixels[p..][0..4];
                const dominant = 2 - index; // BGRA: red=2, green=1, blue=0.
                for (0..3) |channel| if (channel != dominant and center[dominant] <= center[channel] +| 40) return error.ColorBitmapChannelsSwapped;
            }
            std.debug.print("COLOR GLYPH U+{x} scale={d} BGRA={d}x{d} colored={d} antialiased={d}\n", .{ codepoint, scale, bitmap.width, bitmap.height, colored, antialiased });
        }
        plain.setScaleFactor(scale);
        const gray = try plain.rasterizeGlyph(plain.glyphIndexForCodepoint('A'));
        defer gray.deinit(std.heap.page_allocator);
        if (gray.is_color or gray.pixels.len != gray.width * gray.height) return error.GrayGlyphBecameColor;
    }
    std.debug.print("PASS: Windows COLR layers, BGRA channel order, premultiplied alpha, fractional DPI and grayscale control\n", .{});
}
