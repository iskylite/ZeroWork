// CoreText C bridge function declarations

pub const CoreTextShapedGlyph = extern struct {
    glyph_index: u32,
    cluster: u32,
    x_advance: f32,
    y_advance: f32,
    x_offset: f32,
    y_offset: f32,
    is_synthetic_italic: u32, // 1 if glyph needs synthetic italic skew at render time
    is_fallback_font: u32, // 1 if glyph uses a fallback font (e.g. CJK)
    fallback_font_ref: ?*anyopaque, // retained CTFontRef of the actual fallback font (NULL if not fallback)
};

pub const CoreTextCaretStop = extern struct {
    byte_offset: u32,
    primary_x: f32,
    secondary_x: f32,
    has_secondary: u32,
};

pub const CoreTextLineMetrics = extern struct {
    width: f32,
    ascent: f32,
    descent: f32,
    leading: f32,
    base_rtl: u32,
};

// Font creation
pub extern fn coretext_create_font_from_path(path: [*:0]const u8, size: f32) ?*anyopaque;
pub extern fn coretext_create_font_from_path_weighted(path: [*:0]const u8, size: f32, weight: c_int, italic: c_int) ?*anyopaque;
pub extern fn coretext_find_font(family: [*:0]const u8, size: f32, weight: c_int, italic: c_int) ?*anyopaque;
pub extern fn coretext_release_font(font: *anyopaque) void;
pub extern fn coretext_retain_font(font: *anyopaque) void;
/// Derive new font size from existing CTFont, preserving all variation axes (weight/italic).
pub extern fn coretext_derive_font(existing_font: *anyopaque, new_size: f32) ?*anyopaque;
pub extern fn coretext_font_copy_debug_name(font: *anyopaque) ?[*:0]u8;
pub extern fn coretext_free_c_string(str: [*:0]u8) void;

// Font enumeration (font picker). Benchmarked on this machine (macOS 272 families / 990 faces):
// enumeration 17.6ms, full trait scan 40.1ms. Hosts scan once in background; this layer does not
// cache.

/// Field-aligned with C side `CoreTextFamilyInfo`. Changes here must sync to bridge.m.
pub const CoreTextFamilyInfo = extern struct {
    /// Symbolic class == Symbolic: names **cannot** be rendered by the font itself (Wingdings,
    /// etc). Warning: do not use glyph coverage as substitute. Tested: Wingdings returns glyphs for
    /// 'A'/'a' but renders as symbols.
    is_symbolic: c_int,
    /// Whether font contains all glyphs needed to spell its own name. Tested: 47 of 272 families
    /// return 0.
    can_render_name: c_int,
    is_variable: c_int,
    /// Face count in this family. 0 means descriptor lookup failed (e.g., SF Pro); filter from
    /// list.
    face_count: c_int,
    /// See FamilyClass.
    classification: c_int,
    /// Basic Latin glyphs ('A' 'a' 'g' '1'). 0 = rendering English with it produces blanks/tofu.
    has_latin: c_int,
    /// CTFontCopySupportedLanguages()[0], NUL-terminated. Empty = not available.
    lang: [16]u8,
};

pub const FamilyClass = enum(c_int) {
    unknown = 0,
    serif = 1,
    sans = 2,
    script = 3,
    display = 4,
    monospace = 5,
    symbolic = 6,
    _,
};

pub extern fn coretext_family_count() c_int;
/// Write to out_names[0..max), return actual count. Each must be freed with coretext_free_c_string.
pub extern fn coretext_copy_family_names(out_names: [*]?[*:0]u8, max: c_int) c_int;
/// 0 = success, -1 = family name cannot construct a font.
pub extern fn coretext_family_info(family: [*:0]const u8, out: *CoreTextFamilyInfo) c_int;
/// Write to out_styles[0..max), return actual count. Each must be freed with
/// coretext_free_c_string.
pub extern fn coretext_family_styles(family: [*:0]const u8, out_styles: [*]?[*:0]u8, max: c_int) c_int;
/// Actual weight stops available in this family (CSS 100-900, ascending, deduplicated). Returns
/// count written. Warning: weight dropdowns must use this list. CoreText silently downgrades
/// missing weights without error (tested: Zapfino requesting Bold silently gets Regular).
/// Hardcoding 100-900 leaves users selecting without response or signal. Variable fonts populate
/// stops from wght axis range.
pub extern fn coretext_family_weights(family: [*:0]const u8, out_weights: [*]c_int, max: c_int) c_int;
/// Sample string fallback: from font's own character set, take first max_cp renderable codepoints.
/// Used when lang is empty and font is not symbolic (tested: Noto Sans Batak / Tagalog).
pub extern fn coretext_family_sample_codepoints(family: [*:0]const u8, out_cps: [*]u32, max_cp: c_int) c_int;
/// 1 = family name exact match; 0 = does not exist or CoreText silently replaced with different
/// font. Warning: when parsing user-saved font names, **must** check first. coretext_find_font does
/// not fail on missing families; it quietly returns a substitute.
pub extern fn coretext_family_exists(family: [*:0]const u8) c_int;

// Font metrics
pub extern fn coretext_font_get_ascent(font: *anyopaque) f32;
pub extern fn coretext_font_get_descent(font: *anyopaque) f32;
pub extern fn coretext_font_get_leading(font: *anyopaque) f32;
pub extern fn coretext_font_get_units_per_em(font: *anyopaque) c_uint;
pub extern fn coretext_font_get_size(font: *anyopaque) f32;
pub extern fn coretext_font_identity_hash(font: *anyopaque) u64;
pub extern fn coretext_font_get_glyph_index(font: *anyopaque, codepoint: c_uint) c_uint;

// Glyph rasterization
pub extern fn coretext_rasterize_glyph(
    font: *anyopaque,
    glyph_index: c_uint,
    scale_factor: f32,
    out_pixels: *?[*]u8,
    out_width: *c_uint,
    out_height: *c_uint,
    out_bearing_x: *c_int,
    out_bearing_y: *c_int,
    out_advance: *c_int,
    out_is_color: *c_int,
) c_int;

/// Whether font contains color glyph table (sbix / COLR / CBDT, or ColorGlyphs symbolic trait).
pub extern fn coretext_font_has_color_glyphs(font: *anyopaque) c_int;

// Glyph rasterization with subpixel offset and font smoothing on/off
pub extern fn coretext_rasterize_glyph_ex(
    font: *anyopaque,
    glyph_index: c_uint,
    scale_factor: f32,
    subpixel_offset_x: f32,
    subpixel_offset_y: f32,
    smooth_fonts: c_int,
    out_pixels: *?[*]u8,
    out_width: *c_uint,
    out_height: *c_uint,
    out_bearing_x: *c_int,
    out_bearing_y: *c_int,
    out_advance: *c_int,
    out_is_color: *c_int,
) c_int;

// R6: Glyph rasterization with subpixel offset
pub extern fn coretext_rasterize_glyph_subpixel(
    font: *anyopaque,
    glyph_index: c_uint,
    scale_factor: f32,
    subpixel_offset_x: f32,
    subpixel_offset_y: f32,
    out_pixels: *?[*]u8,
    out_width: *c_uint,
    out_height: *c_uint,
    out_bearing_x: *c_int,
    out_bearing_y: *c_int,
    out_advance: *c_int,
    out_is_color: *c_int,
) c_int;

pub extern fn coretext_free_bitmap(pixels: ?[*]u8) void;

// Text shaping
pub extern fn coretext_shape_text(
    font: *anyopaque,
    text: [*]const u8,
    text_len: c_uint,
    out_glyphs: *?[*]CoreTextShapedGlyph,
    out_count: *c_uint,
    synthetic_italic: c_int,
) c_int;

pub extern fn coretext_free_shaped_glyphs(glyphs: ?[*]CoreTextShapedGlyph) void;

/// Extract CoreText-authoritative caret geometry at caller-supplied UTF-8
/// grapheme boundaries. The output preserves primary/secondary positions at
/// bidi boundaries; the Zig side expands and sorts them into visual order.
pub extern fn coretext_line_caret_stops(
    font: *anyopaque,
    text: [*]const u8,
    text_len: c_uint,
    boundaries: [*]const u32,
    boundary_count: c_uint,
    out_stops: [*]CoreTextCaretStop,
    out_metrics: *CoreTextLineMetrics,
) c_int;

// Text measurement with existing font
pub extern fn coretext_measure_text_width_with_font(font: *anyopaque, text: [*]const u8, len: c_int) f32;
