#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// 0=text, 1=absolute Windows file path/file URL/URL, 2=internal UTF8.
// Returns an owned IDataObject reference, or null. All input is copied.
void *zenit_drag_data_create(unsigned kind,const char *bytes,size_t length);
// Resolve the user-visible result after a successful DoDragDrop. Logical Shell
// notification overrides the returned effect when valid and permitted. This
// reports an operation only; it never deletes the source's files or data.
unsigned zenit_drag_data_drop_operation(void *object,unsigned reported,unsigned allowed);
// Decode/scale PNG to an owned top-down straight-alpha BGRA HBITMAP.
// COM must be initialized on the calling STA. Caller must DeleteObject.
// Returns null on malformed input, resource failure or invalid dimensions.
void *zenit_drag_preview_bitmap(const unsigned char *png,size_t length,unsigned width,unsigned height);
#ifdef __cplusplus
}
#endif
