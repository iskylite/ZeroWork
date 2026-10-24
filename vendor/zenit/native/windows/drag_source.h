#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Must run on the owning window thread during a real left-button gesture.
// Copies borrowed input before returning. Session owns one caller reference.
void *zenit_drag_source_start(void *hwnd,unsigned kind,const char *bytes,size_t length,unsigned operations,
    const unsigned char *png,size_t png_length,float width,float height,float hotspot_x,float hotspot_y,uint64_t *token,int *error);
// Polling is nonblocking; completion remains stable until caller releases.
int zenit_drag_source_result(void *session,unsigned *operation,uint64_t *token);
void zenit_drag_source_cancel(void *session);
void zenit_drag_source_release(void *session);
#ifdef __cplusplus
}
#endif
