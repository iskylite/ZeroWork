/* PangoCairo supplies script itemization, bidi, fallback and matching caret geometry.
 * The selected file/index is reopened by FreeType in Zig; Cairo interprets
 * COLRv1 paint graphs that FreeType cannot render into a bitmap itself.
 * Font references own source metadata, independently of layouts and font-map caches. */
#include "text_layout.h"
#include <pango/pangocairo.h>
#include <pango/pangofc-font.h>
#include <pango/pangofc-fontmap.h>
#include <fontconfig/fontconfig.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <cairo-ft.h>
#include <ft2build.h>
#include FT_MULTIPLE_MASTERS_H


void zenit_linux_free_color_bitmap(ZenitLinuxColorBitmap *bitmap) {
    if (bitmap) { free(bitmap->pixels); memset(bitmap, 0, sizeof(*bitmap)); }
}
int zenit_linux_raster_color_glyph(void *ft_face, const char *path, int index, double pixel_size, uint32_t glyph_index, ZenitLinuxColorBitmap *out) {
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    if (!ft_face || !path || index < 0 || !isfinite(pixel_size) || pixel_size <= 0 || pixel_size > 32768) return -1;
    if (!FT_HAS_COLOR((FT_Face)ft_face)) return 0;
    /* FreeType exposes COLRv1 paint graphs but does not rasterize them.
     * Cairo owns its own pattern-backed face: its scaled-font cache must never
     * retain a borrowed FT_Face after the Zig Font has been destroyed. */
    FcPattern *pattern = FcPatternCreate();
    if (!pattern) return -1;
    int ok = FcPatternAddString(pattern, FC_FILE, (const FcChar8 *)path) &&
             FcPatternAddInteger(pattern, FC_INDEX, index) &&
             FcPatternAddDouble(pattern, FC_PIXEL_SIZE, pixel_size);
    if (!ok) { FcPatternDestroy(pattern); return -1; }
    cairo_font_face_t *face = cairo_ft_font_face_create_for_pattern(pattern);
    FcPatternDestroy(pattern);
    cairo_matrix_t font_matrix, ctm;
    cairo_matrix_init_scale(&font_matrix, pixel_size, pixel_size);
    cairo_matrix_init_identity(&ctm);
    cairo_font_options_t *options = cairo_font_options_create();
    cairo_font_options_set_color_mode(options, CAIRO_COLOR_MODE_COLOR);
    cairo_scaled_font_t *font = cairo_scaled_font_create(face, &font_matrix, &ctm, options);
    cairo_font_options_destroy(options);
    cairo_font_face_destroy(face);
    cairo_glyph_t glyph = { glyph_index, 0, 0 };
    cairo_text_extents_t extents;
    cairo_scaled_font_glyph_extents(font, &glyph, 1, &extents);
    double left = floor(extents.x_bearing), top = floor(extents.y_bearing);
    double width = ceil(extents.x_bearing + extents.width) - left;
    double height = ceil(extents.y_bearing + extents.height) - top;
    /* Bound a single atlas glyph to 64 MiB, including malformed font bounds. */
    if (cairo_scaled_font_status(font) != CAIRO_STATUS_SUCCESS ||
        !isfinite(left) || !isfinite(top) || !isfinite(width) || !isfinite(height) ||
        !isfinite(extents.x_advance) || fabs(left) > INT_MAX || fabs(top) > INT_MAX ||
        fabs(extents.x_advance) > INT_MAX || width <= 0 || height <= 0 || width > 4096 || height > 4096) {
        cairo_scaled_font_destroy(font); return -1;
    }
    int w = (int)width, h = (int)height;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    cairo_t *cr = cairo_create(surface);
    cairo_set_scaled_font(cr, font);
    cairo_set_source_rgba(cr, 0, 0, 0, 1);
    glyph.x = -left; glyph.y = -top;
    cairo_show_glyphs(cr, &glyph, 1);
    cairo_surface_flush(surface);
    ok = cairo_status(cr) == CAIRO_STATUS_SUCCESS && cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS;
    unsigned char *pixels = ok ? malloc((size_t)w * (size_t)h * 4) : NULL;
    if (pixels) {
        const unsigned char *data = cairo_image_surface_get_data(surface);
        int stride = cairo_image_surface_get_stride(surface);
        for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
            uint32_t argb;
            memcpy(&argb, data + (size_t)y * stride + (size_t)x * 4, 4);
            size_t offset = ((size_t)y * w + x) * 4;
            pixels[offset] = argb & 255; pixels[offset + 1] = (argb >> 8) & 255;
            pixels[offset + 2] = (argb >> 16) & 255; pixels[offset + 3] = argb >> 24;
        }
        *out = (ZenitLinuxColorBitmap){ pixels, (uint32_t)w, (uint32_t)h, (int32_t)left, (int32_t)-top, (int32_t)round(extents.x_advance) };
    }
    cairo_destroy(cr); cairo_surface_destroy(surface); cairo_scaled_font_destroy(font);
    return pixels ? 1 : -1;
}

typedef struct { uint64_t identity; gint refs; char *path; int index, weight, italic; float size; unsigned axis_count; float *axes; } FontRef;
static uint64_t compute_ref_identity(FontRef *ref);
void zenit_linux_font_ref_retain(void *opaque) { if (opaque) g_atomic_int_inc(&((FontRef *)opaque)->refs); }
void zenit_linux_font_ref_release(void *opaque) {
    FontRef *ref = opaque;
    if (ref && g_atomic_int_dec_and_test(&ref->refs)) { free(ref->axes); free(ref->path); free(ref); }
}
static FontRef *font_ref(PangoFont *font, float size) {
    if (!font || !PANGO_IS_FC_FONT(font)) return NULL;
    FcPattern *pattern = pango_fc_font_get_pattern(PANGO_FC_FONT(font));
    FcChar8 *file = NULL;
    int index = 0;
    if (FcPatternGetString(pattern, FC_FILE, 0, &file) != FcResultMatch || !file) return NULL;
    if (FcPatternGetInteger(pattern, FC_INDEX, 0, &index) != FcResultMatch) index = 0;
    if (index < 0) return NULL;
    FontRef *ref = calloc(1, sizeof(*ref));
    if (!ref) return NULL;
    ref->path = malloc(strlen((const char *)file) + 1);
    if (!ref->path) { free(ref); return NULL; }
    strcpy(ref->path, (const char *)file);
    /* Snapshot the actual scaled FT instance. Pango's HB font can still report
     * default coordinates while Fontconfig requests a non-named instance.
     * The borrowed Cairo face is unlocked before any layout is released. */
    if (!PANGO_IS_CAIRO_FONT(font)) { free(ref->path); free(ref); return NULL; }
    cairo_scaled_font_t *scaled = pango_cairo_font_get_scaled_font(PANGO_CAIRO_FONT(font));
    FT_Face face = scaled ? cairo_ft_scaled_font_lock_face(scaled) : NULL;
    if (!face) { free(ref->path); free(ref); return NULL; }
    int valid = 1;
    if (FT_HAS_MULTIPLE_MASTERS(face)) {
        FT_MM_Var *variation = NULL;
        FT_Fixed coordinates[64];
        if (FT_Get_MM_Var(face, &variation)) valid = 0;
        else {
            ref->axis_count = variation->num_axis;
            valid = ref->axis_count > 0 && ref->axis_count <= 64;
            if (valid) valid = FT_Get_Var_Design_Coordinates(face, ref->axis_count, coordinates) == 0;
            FT_Done_MM_Var(face->glyph->library, variation);
            if (valid) {
                ref->axes = malloc(ref->axis_count * sizeof(float));
                valid = ref->axes != NULL;
                if (valid) for (unsigned i = 0; i < ref->axis_count; ++i)
                    ref->axes[i] = (float)((double)coordinates[i] / 65536.0);
            }
        }
    }
    cairo_ft_scaled_font_unlock_face(scaled);
    if (!valid) { free(ref->axes); free(ref->path); free(ref); return NULL; }
    PangoFontDescription *description = pango_font_describe(font);
    ref->refs = 1;
    ref->index = index;
    ref->size = size;
    ref->weight = pango_font_description_get_weight(description);
    ref->italic = pango_font_description_get_style(description) != PANGO_STYLE_NORMAL;
    pango_font_description_free(description);
    ref->identity = compute_ref_identity(ref);
    return ref;
}
uint64_t zenit_linux_font_ref_identity(void *opaque) {
    FontRef *ref = opaque;
    return ref ? ref->identity : 0;
}
static uint64_t compute_ref_identity(FontRef *ref) {
    uint64_t hash = UINT64_C(14695981039346656037);
    const unsigned char *bytes = (const unsigned char *)ref->path;
    for (size_t i = 0; bytes[i]; ++i) { hash ^= bytes[i]; hash *= UINT64_C(1099511628211); }
    uint32_t size_bits = 0;
    memcpy(&size_bits, &ref->size, sizeof(size_bits));
    const uint32_t fields[] = {(uint32_t)ref->index, (uint32_t)ref->weight, (uint32_t)ref->italic, size_bits};
    for (size_t i = 0; i < sizeof(fields)/sizeof(fields[0]); ++i)
        for (unsigned shift = 0; shift < 32; shift += 8) { hash ^= (fields[i] >> shift) & 255; hash *= UINT64_C(1099511628211); }
    hash ^= ref->axis_count; hash *= UINT64_C(1099511628211);
    for (unsigned i = 0; i < ref->axis_count; ++i) {
        uint32_t bits; memcpy(&bits, &ref->axes[i], sizeof(bits));
        for (unsigned shift = 0; shift < 32; shift += 8) { hash ^= (bits >> shift) & 255; hash *= UINT64_C(1099511628211); }
    }
    return hash;
}
int zenit_linux_font_ref_apply_axes(void *opaque, void *ft_face) {
    FontRef *ref = opaque; FT_Face face = ft_face;
    if (!ref || !face) return 0;
    if (!ref->axis_count) return 1;
    FT_MM_Var *variation = NULL;
    if (FT_Get_MM_Var(face, &variation)) return 0;
    FT_Fixed coords[64];
    int ok = variation->num_axis == ref->axis_count;
    for (unsigned i = 0; ok && i < ref->axis_count; ++i) {
        double coordinate = ref->axes[i];
        if (!isfinite(coordinate)) { ok = 0; break; }
        coordinate = fmax((double)variation->axis[i].minimum / 65536.0, fmin(coordinate, (double)variation->axis[i].maximum / 65536.0));
        coords[i] = (FT_Fixed)round(coordinate * 65536.0);
    }
    FT_Done_MM_Var(face->glyph->library, variation);
    return ok && FT_Set_Var_Design_Coordinates(face, ref->axis_count, coords) == 0;
}
float zenit_linux_font_ref_size(void *opaque) { return opaque ? ((FontRef *)opaque)->size : 0; }
int zenit_linux_font_ref_info(void *opaque, char *path, size_t capacity, int *index, int *weight, int *italic) {
    const FontRef *ref = opaque;
    if (!ref || !path || !index || !weight || !italic || strlen(ref->path) >= capacity) return 0;
    strcpy(path, ref->path); *index = ref->index; *weight = ref->weight; *italic = ref->italic; return 1;
}
void *zenit_linux_text_context_create(void) {
    FcConfig *config = FcConfigCreate();
    if (!config) return NULL;
    if (!FcConfigParseAndLoad(config, NULL, FcTrue) || !FcConfigBuildFonts(config)) { FcConfigDestroy(config); return NULL; }
    PangoFontMap *map = pango_cairo_font_map_new_for_font_type(CAIRO_FONT_TYPE_FT);
    if (map) {
        pango_fc_font_map_set_config(PANGO_FC_FONT_MAP(map), config);
        pango_cairo_font_map_set_resolution(PANGO_CAIRO_FONT_MAP(map), 72);
    }
    FcConfigDestroy(config);
    return map;
}
void zenit_linux_text_context_destroy(void *context) { if (context) g_object_unref(context); }
static PangoLayout *layout_for(void *map, const char *text, size_t length, const char *family, int weight, int italic, float size, float scale) {
    if (!map || !text || !family || length > INT_MAX || !isfinite(size) || !isfinite(scale) || size <= 0 || scale <= 0 || size * scale > 32768 || !g_utf8_validate(text, (gssize)length, NULL)) return NULL;
    PangoContext *context = pango_font_map_create_context(map);
    if (!context) return NULL;
    pango_context_set_round_glyph_positions(context, FALSE);
    PangoLayout *layout = pango_layout_new(context);
    g_object_unref(context);
    PangoFontDescription *description = pango_font_description_new();
    pango_font_description_set_family(description, family);
    pango_font_description_set_weight(description, (PangoWeight)weight);
    pango_font_description_set_style(description, italic ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
    pango_font_description_set_absolute_size(description, (double)size * scale * PANGO_SCALE);
    pango_layout_set_font_description(layout, description);
    pango_font_description_free(description);
    pango_layout_set_single_paragraph_mode(layout, TRUE);
    pango_layout_set_width(layout, -1);
    pango_layout_set_text(layout, text, (int)length);
    return layout;
}
void zenit_linux_free_glyphs(ZenitLinuxGlyph *glyphs, size_t count) {
    for (size_t i = 0; i < count; ++i) zenit_linux_font_ref_release(glyphs[i].font_ref);
    free(glyphs);
}
int zenit_linux_shape(void *context, const char *text, size_t length, const char *family, int weight, int italic, float size, float scale, ZenitLinuxGlyph **out, size_t *count) {
    if (!out || !count) return 0;
    *out = NULL; *count = 0;
    PangoLayout *layout = layout_for(context, text, length, family, weight, italic, size, scale);
    if (!layout) return 0;
    PangoLayoutLine *line = pango_layout_get_line_readonly(layout, 0);
    size_t capacity = 0;
    for (GSList *node = line->runs; node; node = node->next) {
        PangoGlyphItem *run = node->data;
        if (run->glyphs->num_glyphs < 0 || (size_t)run->glyphs->num_glyphs > SIZE_MAX / sizeof(ZenitLinuxGlyph) - capacity) { g_object_unref(layout); return 0; }
        capacity += (size_t)run->glyphs->num_glyphs;
    }
    ZenitLinuxGlyph *glyphs = capacity ? calloc(capacity, sizeof(*glyphs)) : NULL;
    if (capacity && !glyphs) { g_object_unref(layout); return 0; }
    size_t used = 0;
    const float divisor = PANGO_SCALE * scale;
    for (GSList *node = line->runs; node; node = node->next) {
        PangoGlyphItem *run = node->data;
        FontRef *ref = font_ref(run->item->analysis.font, size);
        if (!ref) { zenit_linux_free_glyphs(glyphs, used); g_object_unref(layout); return 0; }
        for (int i = 0; i < run->glyphs->num_glyphs; ++i) {
            PangoGlyphInfo *info = &run->glyphs->glyphs[i];
            if (info->glyph == PANGO_GLYPH_EMPTY) continue;
            const int cluster = run->item->offset + run->glyphs->log_clusters[i];
            if (cluster < 0 || (size_t)cluster > length) { zenit_linux_font_ref_release(ref); zenit_linux_free_glyphs(glyphs, used); g_object_unref(layout); return 0; }
            zenit_linux_font_ref_retain(ref);
            glyphs[used++] = (ZenitLinuxGlyph){
                .glyph_index = (info->glyph & PANGO_GLYPH_UNKNOWN_FLAG) ? 0 : info->glyph,
                .cluster = (uint32_t)cluster, .x_advance = info->geometry.width / divisor,
                .x_offset = info->geometry.x_offset / divisor, .y_offset = info->geometry.y_offset / divisor,
                .font_ref = ref,
            };
        }
        zenit_linux_font_ref_release(ref);
    }
    g_object_unref(layout); *out = glyphs; *count = used; return 1;
}
int zenit_linux_carets(void *context, const char *text, size_t length, const char *family, int weight, int italic, float size, float scale, const uint32_t *boundaries, size_t count, ZenitLinuxCaret *out, ZenitLinuxLineMetrics *metrics) {
    if (!boundaries || !count || !out || !metrics) return 0;
    PangoLayout *layout = layout_for(context, text, length, family, weight, italic, size, scale);
    if (!layout) return 0;
    const float divisor = PANGO_SCALE * scale;
    for (size_t i = 0; i < count; ++i) {
        const uint32_t byte = boundaries[i];
        if (byte > length || (byte < length && (((unsigned char)text[byte] & 0xc0) == 0x80)) || (i && byte <= boundaries[i-1])) { g_object_unref(layout); return 0; }
        PangoRectangle strong, weak;
        pango_layout_get_cursor_pos(layout, (int)byte, &strong, &weak);
        out[i] = (ZenitLinuxCaret){byte, strong.x / divisor, weak.x / divisor, strong.x != weak.x};
    }
    PangoRectangle logical;
    pango_layout_get_extents(layout, NULL, &logical);
    const int baseline = pango_layout_get_baseline(layout);
    PangoLayoutLine *line = pango_layout_get_line_readonly(layout, 0);
    *metrics = (ZenitLinuxLineMetrics){.width = logical.width / divisor, .ascent = (baseline - logical.y) / divisor, .descent = (logical.y + logical.height - baseline) / divisor, .leading = 0, .base_rtl = line->resolved_dir == PANGO_DIRECTION_RTL};
    g_object_unref(layout); return 1;
}
