/* Four independent corners, ordered TL/TR/BR/BL, matching the shared SDF
   renderer's min(width,height)/2 clamp. Native uniform borders are inside the
   outer bounds, not D2D's default centered stroke. Included by d3d11_probe.c. */
static int independent_radii(const ZenitPaintItem *item) {
    return item->shadow_radii[0]!=item->shadow_radii[1] ||
        item->shadow_radii[0]!=item->shadow_radii[2] || item->shadow_radii[0]!=item->shadow_radii[3];
}
static void rounded_figure(ID2D1GeometrySink *sink, float x,float y,float w,float h,const float r[4]) {
    ID2D1GeometrySink_BeginFigure(sink,((D2D1_POINT_2F){x+r[0],y}),D2D1_FIGURE_BEGIN_FILLED);
    const D2D1_POINT_2F lines[4]={{x+w-r[1],y},{x+w,y+h-r[2]},{x+r[3],y+h},{x,y+r[0]}};
    const D2D1_POINT_2F ends[4]={{x+w,y+r[1]},{x+w-r[2],y+h},{x,y+h-r[3]},{x+r[0],y}};
    const unsigned corners[4]={1,2,3,0};
    for (unsigned i=0;i<4;++i) {
        ID2D1GeometrySink_AddLine(sink,lines[i]);
        float radius=r[corners[i]];
        if (radius>0) {
            D2D1_ARC_SEGMENT arc={0};
            arc.point=ends[i]; arc.size=(D2D1_SIZE_F){radius,radius};
            arc.sweepDirection=D2D1_SWEEP_DIRECTION_CLOCKWISE; arc.arcSize=D2D1_ARC_SIZE_SMALL;
            ID2D1GeometrySink_AddArc(sink,&arc);
        } else ID2D1GeometrySink_AddLine(sink,ends[i]);
    }
    ID2D1GeometrySink_EndFigure(sink,D2D1_FIGURE_END_CLOSED);
}
static ID2D1Geometry *rounded_geometry(ZenitD3D11Probe *probe,const ZenitPaintItem *item,int border) {
    if (!isfinite(item->x) || !isfinite(item->y) || !isfinite(item->w) || !isfinite(item->h) ||
        item->w<0 || item->h<0 || !isfinite(item->radius) ||
        (border && (!isfinite(item->stroke_width) || item->stroke_width<0))) return NULL;
    float r[4],limit=fminf(item->w,item->h)/2;
    int varied=independent_radii(item);
    for (unsigned i=0;i<4;++i) {
        float radius=varied ? item->shadow_radii[i] : item->radius;
        if (!isfinite(radius)) return NULL;
        r[i]=fmaxf(0,fminf(radius,limit));
    }
    ID2D1PathGeometry *geometry=NULL; ID2D1GeometrySink *sink=NULL;
    HRESULT hr=ID2D1Factory_CreatePathGeometry(probe->d2d_factory,&geometry);
    if (SUCCEEDED(hr)) hr=ID2D1PathGeometry_Open(geometry,&sink);
    if (SUCCEEDED(hr)) {
        ID2D1GeometrySink_SetFillMode(sink,D2D1_FILL_MODE_ALTERNATE);
        rounded_figure(sink,item->x,item->y,item->w,item->h,r);
        float inset=item->stroke_width;
        if (border && item->w>2*inset && item->h>2*inset) {
            for (unsigned i=0;i<4;++i) r[i]=fmaxf(0,r[i]-inset);
            rounded_figure(sink,item->x+inset,item->y+inset,item->w-2*inset,item->h-2*inset,r);
        }
        hr=ID2D1GeometrySink_Close(sink);
    }
    if (sink) ID2D1GeometrySink_Release(sink);
    if (FAILED(hr)) { if (geometry) ID2D1PathGeometry_Release(geometry); return NULL; }
    return (ID2D1Geometry *)geometry;
}
