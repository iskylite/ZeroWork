#pragma once
#include <stdint.h>
typedef struct ZenitDWriteFont ZenitDWriteFont;
typedef struct ZenitDWriteShapedGlyph ZenitDWriteShapedGlyph;
typedef struct ZenitDWriteCaretStop ZenitDWriteCaretStop;
typedef struct ZenitDWriteLineMetrics ZenitDWriteLineMetrics;
typedef struct ZenitDWriteFontRanges ZenitDWriteFontRanges;
typedef struct ZenitDWriteFontRange {
    void *font;
    uint32_t start, length; /* UTF-16 units, sorted and nonoverlapping. */
    float size; /* Requested layout size in logical pixels. */
    int32_t italic_override; /* -1: source style; 0: normal; 1: italic. */
} ZenitDWriteFontRange;
#ifdef __cplusplus
extern "C" {
#endif
ZenitDWriteFontRanges *zenit_dwrite_create_font_ranges(const ZenitDWriteFontRange *, uint32_t count, uint32_t text_length);
void zenit_dwrite_retain_font_ranges(ZenitDWriteFontRanges *);
void zenit_dwrite_release_font_ranges(ZenitDWriteFontRanges *);
int zenit_dwrite_font_ranges_equal(const ZenitDWriteFontRanges *, const ZenitDWriteFontRanges *);
/* On failure, discard the layout; API errors can leave partial formatting. */
int zenit_dwrite_apply_font_ranges(void *layout, const ZenitDWriteFontRanges *, const uint16_t *text, uint32_t length);
float zenit_dwrite_measure_utf8_with_ranges(ZenitDWriteFont *, const char *, uint32_t length, const ZenitDWriteFontRanges *);
int zenit_dwrite_shape_utf8_with_ranges(ZenitDWriteFont *, const char *, uint32_t length, int italic,
    ZenitDWriteShapedGlyph **, uint32_t *count, const ZenitDWriteFontRanges *);
int zenit_dwrite_line_caret_stops_with_ranges(ZenitDWriteFont *, const char *, uint32_t length,
    const uint32_t *boundaries, uint32_t count, ZenitDWriteCaretStop *, ZenitDWriteLineMetrics *, const ZenitDWriteFontRanges *);
#ifdef __cplusplus
}
#endif
