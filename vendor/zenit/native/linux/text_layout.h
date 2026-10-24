#ifndef ZENIT_LINUX_TEXT_LAYOUT_H
#define ZENIT_LINUX_TEXT_LAYOUT_H
#include <stddef.h>
#include <stdint.h>
typedef struct { uint32_t glyph_index, cluster; float x_advance, y_advance, x_offset, y_offset; void *font_ref; } ZenitLinuxGlyph;
typedef struct { uint32_t byte_offset; float primary_x, secondary_x; uint32_t has_secondary; } ZenitLinuxCaret;
typedef struct { float width, ascent, descent, leading; uint32_t base_rtl; } ZenitLinuxLineMetrics;
void *zenit_linux_text_context_create(void);
void zenit_linux_text_context_destroy(void *context);
int zenit_linux_shape(void *context, const char *text, size_t length, const char *family, int weight, int italic, float size, float scale, ZenitLinuxGlyph **out, size_t *count);
void zenit_linux_free_glyphs(ZenitLinuxGlyph *glyphs, size_t count);
int zenit_linux_carets(void *context, const char *text, size_t length, const char *family, int weight, int italic, float size, float scale, const uint32_t *boundaries, size_t count, ZenitLinuxCaret *out, ZenitLinuxLineMetrics *metrics);
void zenit_linux_font_ref_retain(void *ref);
void zenit_linux_font_ref_release(void *ref);
uint64_t zenit_linux_font_ref_identity(void *ref);
float zenit_linux_font_ref_size(void *ref);
int zenit_linux_font_ref_info(void *ref, char *path, size_t capacity, int *index, int *weight, int *italic);
int zenit_linux_font_ref_apply_axes(void *ref, void *ft_face);
typedef struct { unsigned char *pixels; uint32_t width, height; int32_t bearing_x, bearing_y, advance; } ZenitLinuxColorBitmap;
/* 0: not a color face; 1: owned premultiplied BGRA bitmap; -1: render failure. */
int zenit_linux_raster_color_glyph(void *ft_face, const char *path, int index, double pixel_size, uint32_t glyph, ZenitLinuxColorBitmap *out);
void zenit_linux_free_color_bitmap(ZenitLinuxColorBitmap *bitmap);
#endif
