#ifndef ZENIT_WINDOW_GEOMETRY_H
#define ZENIT_WINDOW_GEOMETRY_H
#include <stdint.h>
#include <limits.h>

typedef void (*ZenitClientQuery)(void *, int, int, int *, int *);

/* Resolve width before the width-dependent menu height. The final query
   verifies fixed insets before any HWND mutation. At most three queries. */
static int zenit_resolve_client_extent(int64_t wanted_w, int64_t wanted_h,
        int cap_w, int cap_h, int w, int h, void *context, ZenitClientQuery query,
        int *outer_w, int *outer_h) {
    if (wanted_w<=0 || wanted_h<=0 || cap_w<=0 || cap_h<=0 || w<=0 || h<=0) return 0;
    int cw,ch;
    w=w<cap_w?w:cap_w;
    /* Measure at the available height: a short seed can collapse the client
       before a wrapped menu's full nonclient height has been established. */
    query(context,w,cap_h,&cw,&ch);
    int inset_w=w-cw;
    int64_t final_w=wanted_w+inset_w;
    if (final_w<=0 || final_w>INT_MAX) return 0;
    w=(int)(final_w<cap_w?final_w:cap_w);
    query(context,w,cap_h,&cw,&ch);
    int inset_h=cap_h-ch;
    int64_t final_h=wanted_h+inset_h;
    if (final_h<=0 || final_h>INT_MAX) return 0;
    h=(int)(final_h<cap_h?final_h:cap_h);
    query(context,w,h,&cw,&ch);
    if (w-cw!=inset_w || h-ch!=inset_h) return 0;
    *outer_w=w; *outer_h=h;
    return 1;
}
typedef struct { int32_t left, top, right, bottom; } ZenitGeometryRect;

/* Ownership preserves placement, including partly offscreen/Snap frames. Only
   a known visible frame entirely outside the work area is brought back. */
static int zenit_fit_owned_geometry(ZenitGeometryRect frame, ZenitGeometryRect visible,
        ZenitGeometryRect work, int visible_known, ZenitGeometryRect *out) {
    int64_t width=(int64_t)frame.right-frame.left, height=(int64_t)frame.bottom-frame.top;
    int64_t vw=(int64_t)visible.right-visible.left, vh=(int64_t)visible.bottom-visible.top;
    int64_t ww=(int64_t)work.right-work.left, wh=(int64_t)work.bottom-work.top;
    if (width<=0 || height<=0 || vw<=0 || vh<=0 || ww<=0 || wh<=0) return 0;
    int64_t left=frame.left, top=frame.top;
    int64_t cap_w=ww+width-vw, cap_h=wh+height-vh;
    if (width>cap_w) width=cap_w;
    if (height>cap_h) height=cap_h;
    if (visible_known && (visible.right<=work.left || visible.left>=work.right ||
            visible.bottom<=work.top || visible.top>=work.bottom)) {
        int64_t inset_left=(int64_t)visible.left-frame.left, inset_top=(int64_t)visible.top-frame.top;
        int64_t fitted_vw=vw<ww?vw:ww, fitted_vh=vh<wh?vh:wh;
        int64_t vx=left+inset_left, vy=top+inset_top;
        if (vx>work.right-fitted_vw) vx=work.right-fitted_vw;
        if (vx<work.left) vx=work.left;
        if (vy>work.bottom-fitted_vh) vy=work.bottom-fitted_vh;
        if (vy<work.top) vy=work.top;
        left=vx-inset_left; top=vy-inset_top;
    }
    if (width<=0 || height<=0 || width>INT_MAX || height>INT_MAX || left<INT_MIN || top<INT_MIN ||
        left+width>INT_MAX || top+height>INT_MAX) return 0;
    *out=(ZenitGeometryRect){(int32_t)left,(int32_t)top,(int32_t)(left+width),(int32_t)(top+height)};
    return 1;
}

#endif
