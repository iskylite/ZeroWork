//! font_registry.zig - process-level family_id <-> family_name registry + on-demand face cache.
//!
//! Why it exists: font decisions recognize (size, weight, italic, mono, symbols) and
//! FontSelector describes **one** family. To let different canvas objects use different
//! fonts, a family axis is added as a u16 id with names centralized here, rather than
//! a name string in TextProps / DisplayItem.text_run / TextFontProps: text_run is
//! **rebuilt every frame**, so a slice inside it must outlive the frame (same shape
//! as setText dangling / on_cleanup UAF). A u16 is self-contained and 14 bytes smaller.
//!
//! Relationship to the downstream application's doc-level FontStore: the two tables
//! **intentionally do not share ids**.
//! - downstream doc/font_store.zig is **document-level**, persists with the doc
//! - this table is **process-level**, serves the render pipeline
//! The host translates once during projection: doc_id -> family_name -> process_id.
//! This keeps docs free of process enumeration order (machine change / new font
//! install would drift).
//!
//! Face cache: each (family, size, weight, italic) combo maps to one *Font. Cold face
//! startup is 0.28~4.87ms, warm 0.03ms (macOS global face cache), so this is a thin
//! cache avoiding repeat findFont; no preload or eviction. Family count is tens.

const std = @import("std");
const text_module = @import("text");
const Font = text_module.Font;

/// 0 = follow FontSelector's default family (the one loaded at host startup).
pub const FamilyId = enum(u16) { default = 0, _ };

pub const NAME_CAP = 64;

const FaceKey = struct {
    family: u16,
    /// size quantized to 0.25px, same granularity as FontSelector's derived cache, avoid
    /// floating-point noise piercing cache.
    size_q: u32,
    weight: u16,
    italic: bool,
};

const FaceCtx = struct {
    pub fn hash(_: FaceCtx, k: FaceKey) u64 {
        var h = std.hash.Wyhash.init(0xFACE);
        h.update(std.mem.asBytes(&k.family));
        h.update(std.mem.asBytes(&k.size_q));
        h.update(std.mem.asBytes(&k.weight));
        h.update(std.mem.asBytes(&k.italic));
        return h.final();
    }
    pub fn eql(_: FaceCtx, a: FaceKey, b: FaceKey) bool {
        return a.family == b.family and a.size_q == b.size_q and
            a.weight == b.weight and a.italic == b.italic;
    }
};

const Entry = struct {
    name: [NAME_CAP]u8 = @as([NAME_CAP]u8, @splat(0)),
    len: u8 = 0,
    pub fn slice(self: *const Entry) []const u8 {
        return self.name[0..self.len];
    }
};

pub const FontRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    faces: std.HashMapUnmanaged(FaceKey, *Font, FaceCtx, 80) = .{},
    font_system: ?*text_module.FontSystem = null,
    /// current HiDPI scale. **new faces must apply it immediately**, else on 2x screens these fonts
    /// rasterize at 1x, appearing 'other text sharp, font selector text blurry'. FontSelector slots
    /// set by App.setScaleFactor uniformly, but this table's faces are created independently, not
    /// on that chain, must manage separately.
    scale_factor: f32 = 1.0,

    pub fn init(allocator: std.mem.Allocator) FontRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FontRegistry) void {
        var it = self.faces.iterator();
        while (it.next()) |kv| kv.value_ptr.*.deinit();
        self.faces.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    /// set once at host startup. when not set, `resolve` always returns null (falls back to default
    /// family).
    pub fn setFontSystem(self: *FontRegistry, fs: *text_module.FontSystem) void {
        self.font_system = fs;
    }

    /// family name -> process-local id. reuse if exists. empty name = `.default`.
    pub fn intern(self: *FontRegistry, name: []const u8) !FamilyId {
        if (name.len == 0) return .default;
        for (self.entries.items, 0..) |*e, i| {
            if (std.mem.eql(u8, e.slice(), name)) return @fromBackingInt(@intCast(i + 1));
        }
        var e = Entry{};
        var n = @min(name.len, NAME_CAP);
        while (n > 0 and n < name.len and (name[n] & 0xC0) == 0x80) n -= 1;
        @memcpy(e.name[0..n], name[0..n]);
        e.len = @intCast(n);
        try self.entries.append(self.allocator, e);
        return @fromBackingInt(@intCast(self.entries.items.len));
    }

    pub fn nameOf(self: *const FontRegistry, id: FamilyId) ?[]const u8 {
        const raw = @backingInt(id);
        if (raw == 0 or raw > self.entries.items.len) return null;
        return self.entries.items[raw - 1].slice();
    }

    /// get face for (family, size, weight, italic). return null = use default family (id=0 /
    /// FontSystem not loaded / family unresolvable). returned `*Font` owned by this table, caller
    /// **borrows without releasing**.
    pub fn resolve(
        self: *FontRegistry,
        family: FamilyId,
        size: f32,
        weight: u16,
        italic: bool,
    ) ?*Font {
        if (family == .default) return null;
        const fs = self.font_system orelse return null;
        const name = self.nameOf(family) orelse return null;

        const key = FaceKey{
            .family = @backingInt(family),
            .size_q = @intFromFloat(@round(@max(1.0, size) * 4.0)),
            .weight = weight,
            .italic = italic,
        };
        if (self.faces.get(key)) |f| return f;

        const desc = text_module.FontDescriptor{
            .family = name,
            .size = size,
            .weight = mapWeight(weight),
            .style = if (italic) .italic else .normal,
        };
        const font = fs.findFont(desc) catch return null;
        // WARN: must apply current scale before cache insertion. missing it = 2x screen rasterizes
        // at 1x, glyphs blurry (same symptom as noted in FontSelector.setScaleFactor comment).
        font.setScaleFactor(self.scale_factor);
        self.faces.put(self.allocator, key, font) catch {
            font.deinit();
            return null;
        };
        return font;
    }

    /// screen DPI changed (dragged to different screen). update all faces' scale in place, don't
    /// clear cache: derived key independent of scale, actual scale-bucketing is downstream in glyph
    /// atlas GlyphKey.scale_q (same as FontSelector.setScaleFactor).
    pub fn setScaleFactor(self: *FontRegistry, scale: f32) void {
        if (self.scale_factor == scale) return;
        self.scale_factor = scale;
        var it = self.faces.valueIterator();
        while (it.next()) |f| f.*.setScaleFactor(scale);
    }

    fn mapWeight(w: u16) text_module.FontWeight {
        return if (w <= 100) .thin else if (w <= 300) .light else if (w <= 400) .regular else if (w <= 500) .medium else if (w <= 600) .semibold else if (w <= 700) .bold else if (w <= 800) .heavy else .black;
    }
};

test "intern 去重、id 从 1 起、default 为 0" {
    var r = FontRegistry.init(std.testing.allocator);
    defer r.deinit();

    try std.testing.expectEqual(FamilyId.default, try r.intern(""));
    const a = try r.intern("Zapfino");
    const b = try r.intern("Menlo");
    const a2 = try r.intern("Zapfino");

    try std.testing.expectEqual(a, a2);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(u16, 1), @backingInt(a));
    try std.testing.expectEqualStrings("Zapfino", r.nameOf(a).?);
    try std.testing.expect(r.nameOf(.default) == null);
    // out-of-bounds id must not return another's name
    try std.testing.expect(r.nameOf(@fromBackingInt(@intCast(999))) == null);
}

test "没装 FontSystem 时 resolve 安全返回 null" {
    var r = FontRegistry.init(std.testing.allocator);
    defer r.deinit();
    const id = try r.intern("Zapfino");
    try std.testing.expect(r.resolve(id, 16, 400, false) == null);
    try std.testing.expect(r.resolve(.default, 16, 400, false) == null);
}
