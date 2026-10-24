const std = @import("std");

/// GlyphBitmap holds rasterized glyph data (platform-agnostic)
pub const GlyphBitmap = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    bearing_x: i32,
    bearing_y: i32,
    advance: i32,
    /// true = pixels are BGRA premultiplied (4 bytes/pixel, color glyphs);
    /// false = single-channel coverage mask (1 byte/pixel).
    is_color: bool = false,
    is_cleartype: bool = false,

    /// Bytes per pixel, determined solely by is_color. Used to calculate bytes_per_row when
    /// uploading texture.
    pub fn bytesPerPixel(self: GlyphBitmap) u32 {
        return if (self.is_color or self.is_cleartype) 4 else 1;
    }

    pub fn deinit(self: GlyphBitmap, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// Shaped glyph info after text shaping (platform-agnostic)
pub const ShapedGlyph = struct {
    glyph_index: u32,
    cluster: u32, // UTF-8 byte offset
    x_advance: f32,
    y_advance: f32,
    x_offset: f32,
    y_offset: f32,
    is_synthetic_italic: bool = false, // true if glyph needs synthetic italic skew at render time
    is_fallback_font: bool = false, // true if glyph uses a fallback font (e.g. CJK)
    /// CoreText actually selected fallback font CTFontRef (retained).
    /// Rasterize with this font at render time, not fixed CJK fallback.
    fallback_font_ref: ?*anyopaque = null,
};

/// Backend-neutral line caret extraction record. One record corresponds to one
/// framework-provided grapheme boundary; `secondary_x` is meaningful only at a
/// bidi boundary where the same logical position has two visual carets.
pub const LineCaretStop = struct {
    byte_offset: u32,
    primary_x: f32,
    secondary_x: f32,
    has_secondary: bool,
};

pub const LineMetrics = struct {
    width: f32,
    ascent: f32,
    descent: f32,
    leading: f32,
    base_rtl: bool,
};

/// Font descriptor for system font discovery
pub const FontDescriptor = struct {
    family: []const u8,
    size: f32,
    weight: FontWeight = .regular,
    style: FontStyle = .normal,
};

pub const FontWeight = enum {
    thin,
    light,
    regular,
    medium,
    semibold,
    bold,
    heavy,
    black,
};

pub const FontStyle = enum {
    normal,
    italic,
};
