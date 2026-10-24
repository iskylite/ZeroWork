#pragma once
#include <stdint.h>
#include <stddef.h>
typedef struct ZenitA11yText { const char *bytes; size_t length; } ZenitA11yText;
typedef struct ZenitA11yOffsets { const uint32_t *bytes; size_t count; } ZenitA11yOffsets;
typedef struct ZenitA11yGeometrySegment {
    uint32_t start, end; /* Input UTF-8 offsets; owned snapshot UTF-16 offsets. */
    float x, y, width, height; /* World logical coordinates; not yet paint-clipped. */
} ZenitA11yGeometrySegment;
typedef struct ZenitA11yGeometry { const ZenitA11yGeometrySegment *segments; size_t count; } ZenitA11yGeometry;
typedef struct ZenitA11yCaretCandidate {
    uint32_t offset; /* Input UTF-8 offset; owned snapshot UTF-16 offset. */
    float first_x, first_y, last_x, last_y; /* Exact transformed caret line. */
    float visible_first_x, visible_first_y, visible_last_x, visible_last_y;
    uint8_t downstream, visible; /* Visible line optional; adjacent glyph may be visible. */
} ZenitA11yCaretCandidate;
typedef struct ZenitA11yCarets { const ZenitA11yCaretCandidate *candidates; size_t count; } ZenitA11yCarets;
typedef struct ZenitA11yNode {
    uint32_t id, parent_index, state;
    uint16_t role;
    uint8_t actions, numeric, setters;
    float x, y, width, height;
    double value_now, value_min, value_max, small_change, large_change;
    ZenitA11yText name, description, value, identifier;
    uint8_t editable, can_set_selection, uniform_format, can_scroll;
    uint32_t selection_start, selection_end, caret, visible_start, visible_end; /* UTF-8 bytes; visible_end UINT32_MAX means all text. */
    ZenitA11yOffsets characters; /* Optional complete grapheme boundaries, UTF-8 bytes, including 0 and text length. */
    ZenitA11yOffsets words, paragraphs, lines; /* Optional complete logical unit boundaries, UTF-8 bytes. */
    uint8_t geometry_ready; /* Distinguishes known empty geometry from unavailable layout. */
    ZenitA11yGeometry geometry;
    uint8_t carets_ready;
    ZenitA11yCarets carets;
    uint8_t rows_ready;
    ZenitA11yGeometry rows; /* Visual row regions; start == end permitted. */
} ZenitA11yNode;
#ifdef __cplusplus
extern "C" {
#endif
void *zenit_uia_create(void *hwnd);
void zenit_uia_destroy(void *binding);
int zenit_uia_publish(void *binding, const ZenitA11yNode *nodes, size_t count);
intptr_t zenit_uia_get_object(void *binding, uintptr_t wparam, intptr_t lparam);
size_t zenit_uia_node_size(void);
typedef int (*ZenitA11yActionCallback)(void *context, uint32_t id, uint8_t action, const char *text, size_t length, double number);
int zenit_uia_set_action_handler(void *binding, void *context, ZenitA11yActionCallback callback);
int zenit_uia_drain(void *binding);
#define ZENIT_UIA_WAKE_MESSAGE 0x803a
#ifdef __cplusplus
}
#endif
