#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d2d1_1.h>
#include <initguid.h>
#include <d2d1effects.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <new>
#include "d2d_composite.h"

template<class T> struct Owned {
    T *p = nullptr;
    ~Owned() { if (p) p->Release(); }
    Owned() = default;
    Owned(const Owned &) = delete;
    Owned &operator=(const Owned &) = delete;
};
static int failed(HRESULT hr, const char *stage) {
    if (SUCCEEDED(hr)) return 0;
    fprintf(stderr, "[windows-composite-error] stage=%s hr=0x%08lx\n", stage, (unsigned long)hr);
    return 1;
}

extern "C" int zenit_d2d_create_device(ID3D11Device *d3d, void **out, ID2D1Factory **factory) {
    Owned<IDXGIDevice> dxgi;
    Owned<ID2D1Factory1> created_factory;
    ID2D1Device *device = nullptr;
    if (failed(d3d->QueryInterface(IID_IDXGIDevice, (void **)&dxgi.p), "dxgi-device") ||
        failed(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,__uuidof(ID2D1Factory1),nullptr,(void **)&created_factory.p),"d2d-factory") ||
        failed(created_factory.p->CreateDevice(dxgi.p,&device), "d2d-device")) return 0;
    *factory=created_factory.p; created_factory.p=nullptr;
    *out = device;
    return 1;
}
extern "C" int zenit_d2d_create_target(void *device, IDXGISwapChain *swapchain, ID2D1RenderTarget **out) {
    Owned<IDXGISurface> surface;
    Owned<ID2D1DeviceContext> dc;
    Owned<ID2D1Bitmap1> bitmap;
    D2D1_BITMAP_PROPERTIES1 props = {};
    props.pixelFormat = {DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE};
    props.dpiX = props.dpiY = 96;
    props.bitmapOptions = D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW;
    if (failed(swapchain->GetBuffer(0, IID_IDXGISurface, (void **)&surface.p), "backbuffer") ||
        failed(((ID2D1Device *)device)->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &dc.p), "main-context") ||
        failed(dc.p->CreateBitmapFromDxgiSurface(surface.p, &props, &bitmap.p), "main-bitmap")) return 0;
    dc.p->SetTarget(bitmap.p);
    // Retained groups use transparent targets, where ClearType is unavailable.
    // Keep glyph coverage identical when a group promotes or falls back.
    dc.p->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    *out = dc.p;
    dc.p = nullptr; // RenderTarget owns this DeviceContext reference.
    return 1;
}
extern "C" void zenit_d2d_release_target(ID2D1RenderTarget *target) {
    if (!target) return;
    static_cast<ID2D1DeviceContext *>(target)->SetTarget(nullptr);
    target->Release();
}
extern "C" void zenit_d2d_release_device(void *device) {
    if (device) ((ID2D1Device *)device)->Release();
}

struct RetainedEntry {
    ID2D1Bitmap1 *bitmap;
    uint32_t id, count;
    uint64_t hash, bytes, stamp;
    int used, valid, in_use;
    D2D1_SIZE_U size;
    D2D1_MATRIX_3X2_F matrix;
    D2D1_RECT_F source;
    float dpi_x,dpi_y;
    ZenitDamageItem damage[128];
};
struct RetainedPool {
    RetainedEntry entries[16];
    uint64_t bytes, clock;
    ZenitRetainedStats stats;
};
static void retained_drop(RetainedPool *pool, RetainedEntry *entry) {
    if (entry->bitmap) entry->bitmap->Release();
    pool->bytes-=entry->bytes;
    *entry={};
}
extern "C" void *zenit_d2d_retained_create(void) { return calloc(1,sizeof(RetainedPool)); }
extern "C" void zenit_d2d_retained_destroy(void *state) {
    RetainedPool *pool=(RetainedPool *)state;
    if (!pool) return;
    for (auto &entry:pool->entries) retained_drop(pool,&entry);
    free(pool);
}
extern "C" void zenit_d2d_retained_stats(void *state, ZenitRetainedStats *out) {
    *out=state ? ((RetainedPool *)state)->stats : ZenitRetainedStats{};
}

struct Composite {
    ID2D1DeviceContext *parent, *child;
    ID2D1Bitmap1 *foreground, *background;
    ID2D1Geometry *geometry;
    D2D1_MATRIX_3X2_F matrix, child_matrix;
    D2D1_RECT_F source;
    D2D1_POINT_2F offset;
    D2D1_SIZE_U size;
    float dpi_x, dpi_y, opacity;
    unsigned mode;
    int passthrough, empty, drawing;
    uint64_t bytes, *budget;
    RetainedPool *retained_pool;
    RetainedEntry *retained_entry;
    const ZenitRetainedInfo *retained_info;
    int retained_mode, retained_enabled, damage_clip;
};
extern "C" void zenit_d2d_composite_offset(void *state,float *x,float *y) {
    Composite *s=(Composite *)state;*x=s&&!s->passthrough?s->offset.x:0;*y=s&&!s->passthrough?s->offset.y:0;
}
static void destroy(Composite *s) {
    if (s->damage_clip) s->child->PopAxisAlignedClip();
    if (s->drawing) s->child->EndDraw();
    if (s->child) { s->child->SetTarget(nullptr); s->child->Release(); }
    if (s->foreground) s->foreground->Release();
    if (s->background) s->background->Release();
    if (s->geometry) s->geometry->Release();
    if (s->budget) *s->budget -= s->bytes;
    if (s->retained_entry) s->retained_entry->in_use=0;
    free(s);
}

extern "C" void *zenit_d2d_composite_begin_padded(void *device, ID2D1RenderTarget **target,
    const D2D1_MATRIX_3X2_F *matrix, const D2D1_RECT_F *source, ID2D1Geometry *geometry,
    float opacity, unsigned mode, int passthrough, uint64_t *budget, float padding) {
    if (mode > 11) return nullptr;
    Composite *s = (Composite *)calloc(1, sizeof(*s));
    if (!s) return nullptr;
    s->parent = static_cast<ID2D1DeviceContext *>(*target);
    s->parent->GetTransform(&s->matrix);
    s->parent->GetDpi(&s->dpi_x, &s->dpi_y);
    s->source = *source;
    s->opacity = opacity;
    s->mode = mode;
    s->passthrough = passthrough;
    D2D1_RECT_F bounds = {};
    for (int i = 0; i < 4; ++i) {
        float x = i & 1 ? source->right : source->left;
        float y = i & 2 ? source->bottom : source->top;
        float tx = x*matrix->_11 + y*matrix->_21 + matrix->_31;
        float ty = x*matrix->_12 + y*matrix->_22 + matrix->_32;
        if (!isfinite(tx) || !isfinite(ty)) { destroy(s); return nullptr; }
        if (!i) bounds = {tx,ty,tx,ty};
        else { bounds.left=fminf(bounds.left,tx); bounds.top=fminf(bounds.top,ty);
               bounds.right=fmaxf(bounds.right,tx); bounds.bottom=fmaxf(bounds.bottom,ty); }
    }
    // Keep filter input beyond the group bounds, while s->source/geometry
    // remain the original coverage. Otherwise fades clamp blur at card edges.
    if (!isfinite(padding) || padding < 0) { destroy(s); return nullptr; }
    bounds.left-=padding; bounds.top-=padding;
    bounds.right+=padding; bounds.bottom+=padding;
    D2D1_SIZE_U parent_size = s->parent->GetPixelSize();
    // Clamp before integer conversion; pixel-aligned origin avoids accumulated
    // fractional translations across nested captures. Two pixels retain AA.
    float sx=s->dpi_x/96, sy=s->dpi_y/96;
    UINT left=(UINT)fmaxf(0,fminf(parent_size.width,floorf(bounds.left*sx)-2));
    UINT top=(UINT)fmaxf(0,fminf(parent_size.height,floorf(bounds.top*sy)-2));
    UINT right=(UINT)fmaxf(0,fminf(parent_size.width,ceilf(bounds.right*sx)+2));
    UINT bottom=(UINT)fmaxf(0,fminf(parent_size.height,ceilf(bounds.bottom*sy)+2));
    s->empty=right<=left || bottom<=top;
    s->size={s->empty ? 1 : right-left,s->empty ? 1 : bottom-top};
    s->offset={left/sx,top/sy};
    s->child_matrix=*matrix;
    s->child_matrix._31-=s->offset.x; s->child_matrix._32-=s->offset.y;
    // Bound live capture storage, including the later coverage bitmap. Never
    // silently degrade a requested blend to normal when allocation fails.
    s->bytes=(uint64_t)s->size.width*s->size.height*12;
    if (s->bytes > UINT64_C(134217728) || *budget > UINT64_C(134217728)-s->bytes) {
        destroy(s); return nullptr;
    }
    s->budget=budget; *budget+=s->bytes;
    if (geometry) { geometry->AddRef(); s->geometry=geometry; }
    D2D1_BITMAP_PROPERTIES1 props={};
    props.pixelFormat={DXGI_FORMAT_B8G8R8A8_UNORM,D2D1_ALPHA_MODE_PREMULTIPLIED};
    props.dpiX=s->dpi_x; props.dpiY=s->dpi_y;
    props.bitmapOptions=D2D1_BITMAP_OPTIONS_TARGET;
    if (failed(((ID2D1Device *)device)->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE,&s->child),"capture-context") ||
        failed(s->child->CreateBitmap(s->size,nullptr,0,&props,&s->foreground),"capture-bitmap")) { destroy(s); return nullptr; }
    props.bitmapOptions=D2D1_BITMAP_OPTIONS_NONE;
    props.pixelFormat=s->parent->GetPixelFormat();
    if (failed(s->child->CreateBitmap(s->size,nullptr,0,&props,&s->background),"backdrop-bitmap")) { destroy(s); return nullptr; }
    if (!s->empty) {
        D2D1_POINT_2U origin={0,0}; D2D1_RECT_U rect={left,top,right,bottom};
        Owned<ID2D1Image> parent_bitmap;
        s->parent->GetTarget(&parent_bitmap.p);
        // All contexts here target bitmaps. CopyFromRenderTarget rejects even
        // an active axis clip; flushing then copying the bitmap keeps the
        // parent's clip stack intact and does not sample the bound target.
        if (failed(s->parent->Flush(),"backdrop-flush") ||
            failed(s->background->CopyFromBitmap(&origin,static_cast<ID2D1Bitmap *>(parent_bitmap.p),&rect),"backdrop-copy")) { destroy(s); return nullptr; }
    }
    s->child->SetTarget(s->foreground);
    s->child->SetDpi(s->dpi_x,s->dpi_y);
    s->child->BeginDraw(); s->drawing=1;
    D2D1_COLOR_F clear={0,0,0,0}; s->child->Clear(clear);
    if (passthrough && !s->empty) s->child->DrawBitmap(s->background);
    s->child->SetTransform(s->child_matrix);
    *target=s->child;
    return s;
}

extern "C" void *zenit_d2d_composite_begin(void *device, ID2D1RenderTarget **target,
    const D2D1_MATRIX_3X2_F *matrix, const D2D1_RECT_F *source, ID2D1Geometry *geometry,
    float opacity, unsigned mode, int passthrough, uint64_t *budget) {
    return zenit_d2d_composite_begin_padded(device,target,matrix,source,geometry,opacity,mode,passthrough,budget,0);
}

static int composite_effect(ID2D1DeviceContext *dc, ID2D1Image *background,
    ID2D1Image *foreground, D2D1_COMPOSITE_MODE mode, ID2D1Effect **out) {
    if (failed(dc->CreateEffect(CLSID_D2D1Composite,out),"composite-effect")) return 0;
    (*out)->SetInput(0,background); (*out)->SetInput(1,foreground);
    return !failed((*out)->SetValue(D2D1_COMPOSITE_PROP_MODE,mode),"composite-mode");
}
static int color_effect(ID2D1DeviceContext *dc, ID2D1Image *input,
    ID2D1ColorContext *source, ID2D1ColorContext *destination, ID2D1Effect **out) {
    if (failed(dc->CreateEffect(CLSID_D2D1ColorManagement,out),"color-effect")) return 0;
    (*out)->SetInput(0,input);
    // MinGW's effects header omits COLORMANAGEMENT_PROP. These are the SDK's
    // SourceContext=0, DestinationContext=2 and Quality=5 property indexes.
    UINT32 quality=2; // D2D1_COLORMANAGEMENT_QUALITY_BEST, an ENUM property.
    if (failed((*out)->SetValue(0,D2D1_PROPERTY_TYPE_COLOR_CONTEXT,(BYTE *)&source,sizeof(source)),"color-source") ||
        failed((*out)->SetValue(2,D2D1_PROPERTY_TYPE_COLOR_CONTEXT,(BYTE *)&destination,sizeof(destination)),"color-destination") ||
        failed((*out)->SetValue(5,D2D1_PROPERTY_TYPE_ENUM,(BYTE *)&quality,sizeof(quality)),"color-quality") ||
        failed((*out)->SetValue(D2D1_PROPERTY_PRECISION,D2D1_BUFFER_PRECISION_32BPC_FLOAT),"color-precision")) return 0;
    return 1;
}

static int draw_composite(Composite *s, int backdrop=0) {
    Owned<ID2D1Bitmap1> coverage;
    Owned<ID2D1SolidColorBrush> white;
    D2D1_BITMAP_PROPERTIES1 props={};
    props.pixelFormat={DXGI_FORMAT_B8G8R8A8_UNORM,D2D1_ALPHA_MODE_PREMULTIPLIED};
    props.dpiX=s->dpi_x; props.dpiY=s->dpi_y;
    props.bitmapOptions=D2D1_BITMAP_OPTIONS_TARGET;
    if (failed(s->child->CreateBitmap(s->size,nullptr,0,&props,&coverage.p),"coverage-bitmap")) return 0;
    s->child->SetTarget(coverage.p);
    s->child->SetTransform(s->child_matrix);
    D2D1_COLOR_F color={1,1,1,s->opacity};
    if (failed(s->child->CreateSolidColorBrush(color,&white.p),"coverage-brush")) return 0;
    s->child->BeginDraw();
    D2D1_COLOR_F clear={0,0,0,0}; s->child->Clear(clear);
    if (s->geometry) s->child->FillGeometry(s->geometry,white.p);
    else s->child->FillRectangle(s->source,white.p);
    HRESULT hr=s->child->EndDraw();
    s->child->SetTarget(nullptr);
    if (failed(hr,"coverage-draw")) return 0;

    Owned<ID2D1Effect> masked, inverse, sum, composite, fg_linear, bg_linear, encoded;
    Owned<ID2D1Image> masked_image, inverse_image, fg_image, bg_image, output;
    if (!composite_effect(s->parent,s->foreground,coverage.p,D2D1_COMPOSITE_MODE_DESTINATION_IN,&masked.p)) return 0;
    masked.p->GetOutput(&masked_image.p);
    if (backdrop) {
        // Paint only filtered glass coverage into the current group. Copying
        // the inherited background around it would duplicate that backdrop in
        // an active native opacity layer and broaden the invalidated region.
        output.p=masked_image.p; output.p->AddRef();
    } else if (s->passthrough) {
        // A geometric clip is not an isolated opacity group: children must
        // blend with the inherited backdrop. Merge F*M + B*(1-M), including
        // alpha, instead of source-over duplicating a translucent backdrop.
        if (!composite_effect(s->parent,s->background,coverage.p,D2D1_COMPOSITE_MODE_DESTINATION_OUT,&inverse.p)) return 0;
        inverse.p->GetOutput(&inverse_image.p);
        if (failed(s->parent->CreateEffect(CLSID_D2D1ArithmeticComposite,&sum.p),"clip-merge")) return 0;
        sum.p->SetInput(0,masked_image.p); sum.p->SetInput(1,inverse_image.p);
        D2D1_VECTOR_4F coefficients={0,1,1,0};
        if (failed(sum.p->SetValue(D2D1_ARITHMETICCOMPOSITE_PROP_COEFFICIENTS,coefficients),"clip-coefficients")) return 0;
        sum.p->GetOutput(&output.p);
    } else if (!s->mode) {
        if (!composite_effect(s->parent,s->background,masked_image.p,D2D1_COMPOSITE_MODE_SOURCE_OVER,&composite.p)) return 0;
        composite.p->GetOutput(&output.p);
    } else {
        static const D2D1_BLEND_MODE modes[]={D2D1_BLEND_MODE_MULTIPLY,
            D2D1_BLEND_MODE_MULTIPLY,D2D1_BLEND_MODE_SCREEN,D2D1_BLEND_MODE_OVERLAY,
            D2D1_BLEND_MODE_DARKEN,D2D1_BLEND_MODE_LIGHTEN,D2D1_BLEND_MODE_COLOR_DODGE,
            D2D1_BLEND_MODE_COLOR_BURN,D2D1_BLEND_MODE_HARD_LIGHT,D2D1_BLEND_MODE_SOFT_LIGHT,
            D2D1_BLEND_MODE_DIFFERENCE,D2D1_BLEND_MODE_EXCLUSION};
        Owned<ID2D1ColorContext> srgb,linear;
        if (failed(s->parent->CreateColorContext(D2D1_COLOR_SPACE_SRGB,nullptr,0,&srgb.p),"srgb-context") ||
            failed(s->parent->CreateColorContext(D2D1_COLOR_SPACE_SCRGB,nullptr,0,&linear.p),"linear-context") ||
            !color_effect(s->parent,masked_image.p,srgb.p,linear.p,&fg_linear.p) ||
            !color_effect(s->parent,s->background,srgb.p,linear.p,&bg_linear.p)) return 0;
        fg_linear.p->GetOutput(&fg_image.p); bg_linear.p->GetOutput(&bg_image.p);
        if (failed(s->parent->CreateEffect(CLSID_D2D1Blend,&composite.p),"blend-effect")) return 0;
        composite.p->SetInput(0,bg_image.p); composite.p->SetInput(1,fg_image.p);
        if (failed(composite.p->SetValue(D2D1_BLEND_PROP_MODE,modes[s->mode]),"blend-mode") ||
            failed(composite.p->SetValue(D2D1_PROPERTY_PRECISION,D2D1_BUFFER_PRECISION_32BPC_FLOAT),"blend-precision")) return 0;
        Owned<ID2D1Image> blended;
        composite.p->GetOutput(&blended.p);
        if (!color_effect(s->parent,blended.p,linear.p,srgb.p,&encoded.p)) return 0;
        encoded.p->GetOutput(&output.p);
    }
    const D2D1_MATRIX_3X2_F identity={1,0,0,1,0,0};
    s->parent->SetTransform(identity);
    D2D1_RECT_F rect={0,0,s->size.width*96/s->dpi_x,s->size.height*96/s->dpi_y};
    // SOURCE_COPY is unbounded: without a destination clip it clears pixels
    // outside the effect's image. Restrict replacement to the captured region.
    D2D1_RECT_F destination={s->offset.x,s->offset.y,s->offset.x+rect.right,s->offset.y+rect.bottom};
    s->parent->PushAxisAlignedClip(destination,D2D1_ANTIALIAS_MODE_ALIASED);
    s->parent->DrawImage(output.p,&s->offset,&rect,D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR,
        backdrop ? D2D1_COMPOSITE_MODE_SOURCE_OVER : D2D1_COMPOSITE_MODE_SOURCE_COPY);
    s->parent->PopAxisAlignedClip();
    s->parent->SetTransform(s->matrix);
    // Deferred graph failures must prevent presentation, not leave stale ink.
    int ok=!failed(s->parent->Flush(),"composite-draw");
    return ok;
}

extern "C" int zenit_d2d_composite_end(void *scope, ID2D1RenderTarget **target, int draw) {
    Composite *s=(Composite *)scope;
    if (s->damage_clip) { s->child->PopAxisAlignedClip(); s->damage_clip=0; }
    HRESULT hr=s->child->EndDraw(); s->drawing=0;
    s->child->SetTarget(nullptr);
    *target=s->parent;
    int ok=!failed(hr,"capture-draw");
    if (ok && draw && !s->empty) ok=draw_composite(s,s->retained_entry!=nullptr);
    if (ok && draw && !s->empty && s->retained_entry) {
        RetainedEntry *entry=s->retained_entry;
        RetainedPool *pool=s->retained_pool;
        if (entry->bitmap!=s->foreground) {
            if (entry->bitmap) entry->bitmap->Release();
            pool->bytes-=entry->bytes;
            entry->bitmap=s->foreground; entry->bitmap->AddRef();
            entry->bytes=(uint64_t)s->size.width*s->size.height*4; pool->bytes+=entry->bytes;
        }
        entry->size=s->size; entry->matrix=s->child_matrix; entry->source=s->source;
        entry->dpi_x=s->dpi_x; entry->dpi_y=s->dpi_y;
        entry->hash=s->retained_info->hash;
        entry->count=s->retained_info->safe ? s->retained_info->count : 0;
        if (entry->count) memcpy(entry->damage,s->retained_info->damage,entry->count*sizeof(ZenitDamageItem));
        entry->valid=1;
        if (s->retained_enabled) {
            if (s->retained_mode==1) ++pool->stats.hits;
            else { ++pool->stats.misses; if (s->retained_mode==2) ++pool->stats.partial; }
        }
    }
    destroy(s);
    return ok;
}

extern "C" void *zenit_d2d_retained_begin(void *device, ID2D1RenderTarget **target,
    const D2D1_MATRIX_3X2_F *matrix, const D2D1_RECT_F *source, ID2D1Geometry *geometry,
    float opacity, uint64_t *budget, void *state, const ZenitRetainedInfo *info, int enabled, int *mode) {
    RetainedPool *pool=(RetainedPool *)state;
    *mode=0;
    if (!pool || info->count>128 || (info->count && !info->damage)) return nullptr;
    // Cache limits decline promotion before capture allocates or changes the
    // target. Large normal groups must still render through native layers.
    float dpi_x,dpi_y;
    (*target)->GetDpi(&dpi_x,&dpi_y);
    D2D1_SIZE_U parent_size=(*target)->GetPixelSize();
    float sx=dpi_x/96,sy=dpi_y/96;
    float left=fmaxf(0,fminf(parent_size.width,floorf((source->left+matrix->_31)*sx)-2));
    float top=fmaxf(0,fminf(parent_size.height,floorf((source->top+matrix->_32)*sy)-2));
    float right=fmaxf(0,fminf(parent_size.width,ceilf((source->right+matrix->_31)*sx)+2));
    float bottom=fmaxf(0,fminf(parent_size.height,ceilf((source->bottom+matrix->_32)*sy)+2));
    if (right<=left || bottom<=top) return nullptr;
    uint64_t estimate=(uint64_t)(right-left)*(uint64_t)(bottom-top)*4;
    if (estimate>UINT64_C(67108864) || estimate>UINT64_C(134217728)/3 ||
        *budget>UINT64_C(134217728)-estimate*3) return nullptr;
    RetainedEntry *entry=nullptr;
    for (auto &slot:pool->entries) if (slot.used && slot.id==info->id) { entry=&slot; break; }
    if (entry && entry->in_use) return nullptr;
    if (!entry) {
        for (auto &slot:pool->entries) if (!slot.used) { entry=&slot; break; }
        if (!entry) for (auto &slot:pool->entries)
            if (!slot.in_use && (!entry || slot.stamp<entry->stamp)) entry=&slot;
        if (!entry) return nullptr;
        retained_drop(pool,entry); entry->used=1; entry->id=info->id;
    }
    Composite *s=(Composite *)zenit_d2d_composite_begin(device,target,matrix,source,geometry,opacity,0,0,budget);
    if (!s) { *mode=-1; return nullptr; }
    uint64_t bytes=(uint64_t)s->size.width*s->size.height*4;
    if (s->empty || bytes>UINT64_C(67108864)) {
        *target=s->parent; destroy(s); return nullptr;
    }
    while (pool->bytes-entry->bytes+bytes>UINT64_C(67108864)) {
        RetainedEntry *victim=nullptr;
        for (auto &slot:pool->entries)
            if (&slot!=entry && !slot.in_use && slot.bitmap && (!victim || slot.stamp<victim->stamp)) victim=&slot;
        if (!victim) { *target=s->parent; destroy(s); return nullptr; }
        retained_drop(pool,victim);
    }
    entry->in_use=1; entry->stamp=++pool->clock;
    s->retained_pool=pool; s->retained_entry=entry; s->retained_info=info;
    s->retained_mode=3; s->retained_enabled=enabled;
    // Disabled reuse still paints a fresh isolated foreground. Using native
    // PushLayer here would change glyph rasterization and cannot serve as a
    // pixel reference for the retained texture path.
    int matches=enabled && entry->valid && entry->bitmap && entry->size.width==s->size.width && entry->size.height==s->size.height &&
        entry->dpi_x==s->dpi_x && entry->dpi_y==s->dpi_y &&
        !memcmp(&entry->matrix,&s->child_matrix,sizeof(entry->matrix)) && !memcmp(&entry->source,&s->source,sizeof(entry->source));
    D2D1_RECT_F dirty={INFINITY,INFINITY,-INFINITY,-INFINITY};
    if (matches && entry->hash==info->hash) s->retained_mode=1;
    else if (matches && entry->count && info->safe && info->count &&
        !GetEnvironmentVariableW(L"ZENIT_DISABLE_PARTIAL_REPAINT",nullptr,0)) {
        unsigned n=entry->count>info->count ? entry->count : info->count;
        for (unsigned i=0;i<n;++i) {
            if (i<entry->count && i<info->count && entry->damage[i].digest==info->damage[i].digest &&
                !memcmp(entry->damage[i].bounds,info->damage[i].bounds,4*sizeof(float))) continue;
            for (unsigned side=0;side<2;++side) {
                if (i>=(side ? info->count : entry->count)) continue;
                const float *b=side ? info->damage[i].bounds : entry->damage[i].bounds;
                if (!isfinite(b[0]) || !isfinite(b[1]) || !isfinite(b[2]) || !isfinite(b[3]) || b[2]<0 || b[3]<0) {
                    dirty={-INFINITY,-INFINITY,INFINITY,INFINITY}; break;
                }
                dirty.left=fminf(dirty.left,b[0]); dirty.top=fminf(dirty.top,b[1]);
                dirty.right=fmaxf(dirty.right,b[0]+b[2]); dirty.bottom=fmaxf(dirty.bottom,b[1]+b[3]);
            }
        }
        // Eligibility requires translation-only transforms. Convert global
        // logical damage to this capture, align outwards and pad one pixel.
        float sx=s->dpi_x/96,sy=s->dpi_y/96;
        dirty={floorf((dirty.left+s->child_matrix._31)*sx-1)/sx,
            floorf((dirty.top+s->child_matrix._32)*sy-1)/sy,
            ceilf((dirty.right+s->child_matrix._31)*sx+1)/sx,
            ceilf((dirty.bottom+s->child_matrix._32)*sy+1)/sy};
        dirty.left=fmaxf(0,dirty.left); dirty.top=fmaxf(0,dirty.top);
        dirty.right=fminf(s->size.width/sx,dirty.right); dirty.bottom=fminf(s->size.height/sy,dirty.bottom);
        float area=(dirty.right-dirty.left)*(dirty.bottom-dirty.top);
        float total=(s->size.width/sx)*(s->size.height/sy);
        if (isfinite(area) && dirty.right>dirty.left && dirty.bottom>dirty.top && area<total*.6f) s->retained_mode=2;
    }
    if (s->retained_mode<3) {
        HRESULT hr=s->child->EndDraw(); s->drawing=0;
        s->child->SetTarget(nullptr);
        if (failed(hr,"retained-empty-pass")) { *target=s->parent; destroy(s); *mode=-1; return nullptr; }
        s->foreground->Release(); s->foreground=entry->bitmap; s->foreground->AddRef();
        s->child->SetTarget(s->foreground); s->child->BeginDraw(); s->drawing=1;
        if (s->retained_mode==2) {
            entry->valid=0; // an interrupted partial write can never be reused
            s->child->SetTransform(D2D1_MATRIX_3X2_F{1,0,0,1,0,0});
            s->child->PushAxisAlignedClip(dirty,D2D1_ANTIALIAS_MODE_ALIASED); s->damage_clip=1;
            s->child->Clear(D2D1_COLOR_F{0,0,0,0});
        }
        s->child->SetTransform(s->child_matrix);
    }
    *mode=s->retained_mode;
    return s;
}

// Build an alpha mask in the glass's local coordinate system. Sampled stops
// approximate the shared smoothstep profile to better than one alpha byte;
// the GPU still performs all image filtering and compositing.
static int backdrop_mask(Composite *s, const D2D1_RECT_F *rect,
    const ZenitBackdrop *p, ID2D1Bitmap1 **out) {
    D2D1_BITMAP_PROPERTIES1 props={};
    props.pixelFormat={DXGI_FORMAT_B8G8R8A8_UNORM,D2D1_ALPHA_MODE_PREMULTIPLIED};
    props.dpiX=s->dpi_x; props.dpiY=s->dpi_y;
    props.bitmapOptions=D2D1_BITMAP_OPTIONS_TARGET;
    if (failed(s->child->CreateBitmap(s->size,nullptr,0,&props,out),"blur-mask")) return 0;
    Owned<ID2D1GradientStopCollection> collection;
    Owned<ID2D1LinearGradientBrush> brush;
    D2D1_GRADIENT_STOP stops[257];
    unsigned count=p->count;
    if (count<1 || count>4 || p->direction>4) return 0;
    unsigned stop_count=0;
    auto append=[&](float t,float profile) {
        float weight=p->direction ? p->level+(profile-p->level)*p->strength : p->level;
        stops[stop_count++]={t,{1,1,1,fmaxf(0,fminf(1,weight))}};
    };
    append(0,p->strengths[0]);
    for (unsigned i=0;i+1<count;++i) {
        // Subdivide each stop interval, not the whole axis: narrow profiles
        // keep their declared positions, and duplicate stops retain a jump.
        for (unsigned j=0;j<=64;++j) {
            float u=j/64.0f;
            append(p->positions[i]+(p->positions[i+1]-p->positions[i])*u,
                p->strengths[i]+(p->strengths[i+1]-p->strengths[i])*u*u*(3-2*u));
        }
    }
    append(1,p->strengths[count-1]);
    D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES gradient={};
    gradient.startPoint={rect->left,rect->top};
    gradient.endPoint={rect->left,rect->bottom};
    if (p->direction==2) { gradient.startPoint.y=rect->bottom; gradient.endPoint.y=rect->top; }
    if (p->direction>=3) {
        gradient.endPoint={rect->right,rect->top};
        if (p->direction==4) { gradient.startPoint.x=rect->right; gradient.endPoint.x=rect->left; }
    }
    if (failed(s->child->CreateGradientStopCollection(stops,stop_count,D2D1_GAMMA_2_2,D2D1_EXTEND_MODE_CLAMP,&collection.p),"blur-stops") ||
        failed(s->child->CreateLinearGradientBrush(&gradient,nullptr,collection.p,&brush.p),"blur-gradient")) return 0;
    s->child->SetTarget(*out);
    s->child->SetTransform(s->child_matrix);
    s->child->BeginDraw();
    D2D1_COLOR_F clear={0,0,0,0}; s->child->Clear(clear);
    s->child->FillRectangle(s->source,brush.p);
    HRESULT hr=s->child->EndDraw();
    s->child->SetTarget(nullptr);
    return !failed(hr,"blur-mask-draw");
}

struct LumSlot {
    uint32_t owner;
    uint64_t seen;
    int used, pending, valid;
    float value;
    ID3D11Texture2D *gpu, *staging;
    ID2D1Bitmap1 *bitmap;
    ID3D11Query *ready;
};
struct Luminance {
    ID3D11Device *device;
    ID3D11DeviceContext *gpu;
    ID2D1DeviceContext *dc;
    uint64_t frame;
    LumSlot slots[12];
};
static void lum_release(LumSlot *s) {
    if (s->bitmap) s->bitmap->Release();
    if (s->gpu) s->gpu->Release();
    if (s->staging) s->staging->Release();
    if (s->ready) s->ready->Release();
    *s={};
}
extern "C" void *zenit_d2d_luminance_create(ID3D11Device *device, void *d2d) {
    Luminance *s=(Luminance *)calloc(1,sizeof(Luminance));
    if (!s) return nullptr;
    if (FAILED(((ID2D1Device *)d2d)->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE,&s->dc))) {
        free(s); return nullptr;
    }
    s->device=device; device->AddRef(); device->GetImmediateContext(&s->gpu);
    return s;
}
extern "C" void zenit_d2d_luminance_destroy(void *state) {
    Luminance *s=(Luminance *)state;
    if (!s) return;
    s->dc->SetTarget(nullptr);
    for (auto &slot:s->slots) lum_release(&slot);
    s->dc->Release(); s->gpu->Release(); s->device->Release(); free(s);
}
static void lum_poll(Luminance *s) {
    for (auto &slot:s->slots) {
        if (!slot.pending) continue;
        BOOL complete=FALSE;
        HRESULT hr=s->gpu->GetData(slot.ready,&complete,sizeof(complete),D3D11_ASYNC_GETDATA_DONOTFLUSH);
        if (hr==S_FALSE || (hr==S_OK && !complete)) continue;
        if (FAILED(hr)) { slot.pending=0; slot.valid=0; continue; }
        D3D11_MAPPED_SUBRESOURCE mapped={};
        hr=s->gpu->Map(slot.staging,0,D3D11_MAP_READ,D3D11_MAP_FLAG_DO_NOT_WAIT,&mapped);
        if (hr==DXGI_ERROR_WAS_STILL_DRAWING) continue;
        slot.pending=0;
        if (FAILED(hr)) { slot.valid=0; continue; }
        double sum=0, weight=0;
        for (unsigned y=0;y<64;++y) {
            const float *p=(const float *)((const unsigned char *)mapped.pData+y*mapped.RowPitch);
            for (unsigned x=0;x<64;++x,p+=4) {
                if (!isfinite(p[0]) || !isfinite(p[1]) || !isfinite(p[2]) || !isfinite(p[3])) continue;
                sum+=.2126*p[0]+.7152*p[1]+.0722*p[2]; weight+=p[3];
            }
        }
        s->gpu->Unmap(slot.staging,0);
        slot.valid=weight>0;
        if (slot.valid) slot.value=(float)fmax(0,fmin(1,sum/weight));
    }
}
extern "C" void zenit_d2d_luminance_begin_frame(void *state) {
    Luminance *s=(Luminance *)state;
    if (s) { lum_poll(s); ++s->frame; }
}
extern "C" unsigned zenit_d2d_luminance_read(void *state, ZenitLuminance *out, unsigned capacity) {
    Luminance *s=(Luminance *)state;
    if (!s) return 0;
    lum_poll(s);
    unsigned n=0;
    for (auto &slot:s->slots)
        if (slot.used && slot.valid && slot.seen==s->frame && n<capacity)
            out[n++]={slot.owner,slot.value};
    return n;
}
static int lum_resources(Luminance *s, LumSlot *slot) {
    D3D11_TEXTURE2D_DESC desc={};
    desc.Width=desc.Height=64; desc.MipLevels=desc.ArraySize=1;
    desc.Format=DXGI_FORMAT_R32G32B32A32_FLOAT; desc.SampleDesc.Count=1;
    desc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
    if (failed(s->device->CreateTexture2D(&desc,nullptr,&slot->gpu),"lum-target")) return 0;
    desc.BindFlags=0; desc.Usage=D3D11_USAGE_STAGING; desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    if (failed(s->device->CreateTexture2D(&desc,nullptr,&slot->staging),"lum-staging")) return 0;
    D3D11_QUERY_DESC query={D3D11_QUERY_EVENT,0};
    if (failed(s->device->CreateQuery(&query,&slot->ready),"lum-query")) return 0;
    Owned<IDXGISurface> surface;
    D2D1_BITMAP_PROPERTIES1 props={};
    props.pixelFormat={DXGI_FORMAT_R32G32B32A32_FLOAT,D2D1_ALPHA_MODE_PREMULTIPLIED};
    props.dpiX=props.dpiY=96; props.bitmapOptions=D2D1_BITMAP_OPTIONS_TARGET;
    return !failed(slot->gpu->QueryInterface(IID_IDXGISurface,(void **)&surface.p),"lum-surface") &&
        !failed(s->dc->CreateBitmapFromDxgiSurface(surface.p,&props,&slot->bitmap),"lum-bitmap");
}
static void lum_sample(Luminance *s, Composite *capture, ID2D1Image *linear,
    const D2D1_RECT_F *rect, uint32_t owner) {
    if (!s || owner==UINT32_MAX || capture->empty) return;
    LumSlot *slot=nullptr;
    for (auto &entry:s->slots) if (entry.used && entry.owner==owner) { slot=&entry; break; }
    if (!slot) for (auto &entry:s->slots)
        if (!entry.used || (!entry.pending && entry.seen+1<s->frame)) { slot=&entry; break; }
    if (!slot) return; // bounded pool; never evict an in-flight owner's result
    if (!slot->used || slot->owner!=owner) {
        lum_release(slot);
        if (!lum_resources(s,slot)) { lum_release(slot); return; }
        slot->used=1; slot->owner=owner;
    }
    slot->seen=s->frame;
    if (slot->pending) return;
    // Materialize linear light at source resolution before scaling. Letting
    // D2D evaluate ColorManagement under the downsample transform interpolates
    // the sRGB input first, producing ~0.25 for a 0.52 black/white average.
    uint64_t linear_bytes=(uint64_t)capture->size.width*capture->size.height*16;
    if (linear_bytes>UINT64_C(134217728)-*capture->budget) return;
    Owned<ID2D1Bitmap1> raster;
    D2D1_BITMAP_PROPERTIES1 props={};
    props.pixelFormat={DXGI_FORMAT_R32G32B32A32_FLOAT,D2D1_ALPHA_MODE_PREMULTIPLIED};
    props.dpiX=capture->dpi_x; props.dpiY=capture->dpi_y;
    props.bitmapOptions=D2D1_BITMAP_OPTIONS_TARGET;
    if (failed(capture->child->CreateBitmap(capture->size,nullptr,0,&props,&raster.p),"lum-linear-bitmap")) return;
    capture->child->SetTarget(raster.p);
    capture->child->SetTransform(D2D1_MATRIX_3X2_F{1,0,0,1,0,0});
    capture->child->BeginDraw();
    capture->child->Clear(D2D1_COLOR_F{0,0,0,0});
    capture->child->DrawImage(linear,nullptr,nullptr,D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR);
    HRESULT raster_hr=capture->child->EndDraw(); capture->child->SetTarget(nullptr);
    if (failed(raster_hr,"lum-linear-raster")) return;
    const auto &cm=capture->child_matrix;
    D2D1::Matrix3x2F inverse(cm._11,cm._12,cm._21,cm._22,cm._31,cm._32);
    if (!inverse.Invert()) return;
    float w=rect->right-rect->left,h=rect->bottom-rect->top;
    if (w<=0 || h<=0) return;
    D2D1::Matrix3x2F panel(64/w,0,0,64/h,-rect->left*64/w,-rect->top*64/h);
    // The geometric mask is in panel-local coordinates; the snapshot image
    // is in capture coordinates. Invert its affine map before downsampling.
    s->dc->SetTarget(slot->bitmap); s->dc->SetDpi(96,96); s->dc->BeginDraw();
    s->dc->Clear(D2D1_COLOR_F{0,0,0,0}); s->dc->SetTransform(panel);
    D2D1_LAYER_PARAMETERS1 layer={};
    layer.contentBounds={rect->left,rect->top,rect->right,rect->bottom};
    layer.geometricMask=capture->geometry; layer.maskAntialiasMode=D2D1_ANTIALIAS_MODE_PER_PRIMITIVE;
    layer.maskTransform=D2D1_MATRIX_3X2_F{1,0,0,1,0,0}; layer.opacity=1;
    s->dc->PushLayer(layer,nullptr);
    s->dc->SetTransform(inverse*panel);
    s->dc->DrawImage(raster.p,nullptr,nullptr,D2D1_INTERPOLATION_MODE_HIGH_QUALITY_CUBIC);
    s->dc->PopLayer();
    HRESULT hr=s->dc->EndDraw(); s->dc->SetTarget(nullptr);
    if (failed(hr,"lum-downsample")) return;
    s->gpu->CopyResource(slot->staging,slot->gpu); s->gpu->End(slot->ready);
    slot->pending=1;
}

// Two-input GPU optical composite.
#include "glass_effect.h"

extern "C" int zenit_d2d_backdrop(void *device, ID2D1RenderTarget **target,
    const D2D1_RECT_F *rect, ID2D1Geometry *geometry, const ZenitBackdrop *p,
    uint64_t *budget, void *luminance) {
    const float scalars[]={p->radius,p->level,p->saturation,p->brightness,p->strength,p->thickness};
    for (float v:scalars) if (!isfinite(v)) return 0;
    if (p->radius<0 || p->radius>96 || p->level<0 || p->level>1 ||
        p->saturation<0 || p->saturation>4 || p->brightness<0 || p->brightness>3 ||
        p->strength<0 || p->strength>1 || p->count<1 || p->count>4 || p->direction>4) return 0;
    if(p->thickness<0 || p->thickness>20)return 0;
    for(float v:p->tint)if(!isfinite(v)||v<0||v>1)return 0;
    for (unsigned i=0;i<p->count;++i)
        if (!isfinite(p->positions[i]) || !isfinite(p->strengths[i]) || p->positions[i]<0 || p->positions[i]>1 ||
            p->strengths[i]<0 || p->strengths[i]>1 || (i && p->positions[i]<p->positions[i-1])) return 0;
    const float *params[]={p->optic,p->specular,p->surface,p->bottom,p->lens,p->radii,p->matrix};
    for(unsigned j=0;j<7;++j)for(unsigned i=0;i<(j==6?6u:4u);++i)if(!isfinite(params[j][i]))return 0;
    bool optical=p->optic[0]>0 || p->optic[2]>0 || p->surface[3]!=0 ||
        (p->tint[3]>.005f && (p->tint[0]!=1 || p->tint[1]!=1 || p->tint[2]!=1));
    D2D1_MATRIX_3X2_F parent;
    (*target)->GetTransform(&parent);
    const float *m=p->matrix;
    D2D1_MATRIX_3X2_F matrix={m[0]*parent._11+m[1]*parent._21,m[0]*parent._12+m[1]*parent._22,
        m[2]*parent._11+m[3]*parent._21,m[2]*parent._12+m[3]*parent._22,
        m[4]*parent._11+m[5]*parent._21+parent._31,m[4]*parent._12+m[5]*parent._22+parent._32};
    // Optical displacement/magnification also needs sharp pixels beyond the
    // primitive; a blur radius of zero still captures a real backdrop margin.
    float pad=3*p->radius+2;
    if(optical) {
        // Match the shared lens capture's shape margin (short axis, max80).
        // A full-height sidebar must not pad horizontally by its height: that
        // captured half the window and exhausted the float-image budget.
        float geometry_pad=fmaxf(12,fminf(80,.35f*fminf(rect->right-rect->left,rect->bottom-rect->top)+8));
        pad=fmaxf(pad,geometry_pad);
    }
    D2D1_RECT_F expanded={rect->left-pad,rect->top-pad,rect->right+pad,rect->bottom+pad};
    Composite *s=(Composite *)zenit_d2d_composite_begin(device,target,&matrix,&expanded,geometry,1,0,1,budget);
    if (!s) return 0;
    uint64_t extra=(uint64_t)s->size.width*s->size.height*(optical?68:4);
    if (extra>UINT64_C(134217728)-*budget) {
        fprintf(stderr,"[windows-composite-error] stage=backdrop-budget size=%ux%u live=%llu extra=%llu optical=%d\n",
            s->size.width,s->size.height,(unsigned long long)*budget,(unsigned long long)extra,(int)optical);
        *target=s->parent; destroy(s); return 0;
    }
    *budget+=extra; s->bytes+=extra;
    // This is an immediate backdrop operation, not a group containing children.
    HRESULT hr=s->child->EndDraw(); s->drawing=0;
    s->child->SetTarget(nullptr);
    *target=s->parent;
    int ok=0;
    if (!failed(hr,"blur-capture-end") && !s->empty) {
        Owned<ID2D1ColorContext> srgb,linear;
        Owned<ID2D1Effect> decoded,blur,color,masked_blur,masked_sharp,sum,glass,encoded;
        Owned<ID2D1Image> sharp,blurred,adjusted,blur_part,sharp_part,mixed,output;
        Owned<ID2D1Bitmap1> mask;
        if (failed(s->child->CreateColorContext(D2D1_COLOR_SPACE_SRGB,nullptr,0,&srgb.p),"blur-srgb") ||
            failed(s->child->CreateColorContext(D2D1_COLOR_SPACE_SCRGB,nullptr,0,&linear.p),"blur-linear") ||
            !color_effect(s->child,s->background,srgb.p,linear.p,&decoded.p)) goto finish;
        decoded.p->GetOutput(&sharp.p);
        lum_sample((Luminance *)luminance,s,sharp.p,rect,p->owner_id);
        if (failed(s->child->CreateEffect(CLSID_D2D1GaussianBlur,&blur.p),"gaussian-blur")) goto finish;
        blur.p->SetInput(0,sharp.p);
        if (failed(blur.p->SetValue(D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION,p->radius),"blur-radius") ||
            failed(blur.p->SetValue(D2D1_GAUSSIANBLUR_PROP_BORDER_MODE,D2D1_BORDER_MODE_HARD),"blur-border") ||
            failed(blur.p->SetValue(D2D1_PROPERTY_PRECISION,D2D1_BUFFER_PRECISION_32BPC_FLOAT),"blur-precision")) goto finish;
        blur.p->GetOutput(&blurred.p);
        if(optical) {
            D2D1_MATRIX_3X2_F inv=s->child_matrix;
            if(!D2D1InvertMatrix(&inv))goto finish;
            float dx=s->dpi_x/96,dy=s->dpi_y/96,scale=sqrtf(dx*dy);
            float cx=(rect->left+rect->right)*.5f,cy=(rect->top+rect->bottom)*.5f;
            GlassConstants c={};c.extent[0]=(float)s->size.width;c.extent[1]=(float)s->size.height;
            c.rect[0]=(rect->right-rect->left)*scale;c.rect[1]=(rect->bottom-rect->top)*scale;
            c.rect[2]=scale;c.rect[3]=p->optic[0];
            memcpy(c.tint,p->tint,sizeof(c.tint));memcpy(c.specular,p->specular,sizeof(c.specular));c.specular[3]=p->level;
            c.optic[0]=p->optic[1];c.optic[1]=p->thickness;c.optic[2]=p->optic[2];
            memcpy(c.surface,p->surface,sizeof(c.surface));memcpy(c.bottom,p->bottom,sizeof(c.bottom));
            c.bottom[2]=p->saturation;c.bottom[3]=p->brightness;memcpy(c.lens,p->lens,sizeof(c.lens));
            c.edge[0]=(float)p->direction;c.edge[2]=p->strength;c.edge[3]=(float)p->count;
            memcpy(c.positions,p->positions,sizeof(c.positions));memcpy(c.strengths,p->strengths,sizeof(c.strengths));
            for(unsigned i=0;i<4;++i)c.radii[i]=p->radii[i]*scale;
            c.local[0][0]=inv._11/dx*scale;c.local[0][1]=inv._21/dy*scale;c.local[0][2]=(inv._31-cx)*scale;
            c.local[1][0]=inv._12/dx*scale;c.local[1][1]=inv._22/dy*scale;c.local[1][2]=(inv._32-cy)*scale;
            c.forward[0][0]=s->child_matrix._11*dx/scale;c.forward[0][1]=s->child_matrix._21*dx/scale;
            c.forward[1][0]=s->child_matrix._12*dy/scale;c.forward[1][1]=s->child_matrix._22*dy/scale;
            c.forward[0][2]=(cx*s->child_matrix._11+cy*s->child_matrix._21+s->child_matrix._31)*dx;
            c.forward[1][2]=(cx*s->child_matrix._12+cy*s->child_matrix._22+s->child_matrix._32)*dy;
            if(!glass_effect(s->child,blurred.p,sharp.p,c,&glass.p))goto finish;
            glass.p->GetOutput(&adjusted.p);
            if(!color_effect(s->child,adjusted.p,linear.p,srgb.p,&encoded.p))goto finish;
        } else {
            if (!backdrop_mask(s,rect,p,&mask.p) ||
                !composite_effect(s->child,blurred.p,mask.p,D2D1_COMPOSITE_MODE_DESTINATION_IN,&masked_blur.p) ||
                !composite_effect(s->child,sharp.p,mask.p,D2D1_COMPOSITE_MODE_DESTINATION_OUT,&masked_sharp.p)) goto finish;
            masked_blur.p->GetOutput(&blur_part.p); masked_sharp.p->GetOutput(&sharp_part.p);
            if (failed(s->child->CreateEffect(CLSID_D2D1ArithmeticComposite,&sum.p),"blur-mix")) goto finish;
            sum.p->SetInput(0,blur_part.p); sum.p->SetInput(1,sharp_part.p);
            {
                D2D1_VECTOR_4F coefficients={0,1,1,0};
                if (failed(sum.p->SetValue(D2D1_ARITHMETICCOMPOSITE_PROP_COEFFICIENTS,coefficients),"blur-mix-coefficients")) goto finish;
            }
            sum.p->GetOutput(&mixed.p);
            if (failed(s->child->CreateEffect(CLSID_D2D1ColorMatrix,&color.p),"backdrop-color")) goto finish;
            color.p->SetInput(0,mixed.p);
            {
                float sat=p->saturation,b=p->brightness,k=1-sat;
                D2D1_MATRIX_5X4_F m={
                    b*(.2126f*k+sat),b*.2126f*k,b*.2126f*k,0,
                    b*.7152f*k,b*(.7152f*k+sat),b*.7152f*k,0,
                    b*.0722f*k,b*.0722f*k,b*(.0722f*k+sat),0,
                    0,0,0,1,0,0,0,0};
                if (failed(color.p->SetValue(D2D1_COLORMATRIX_PROP_COLOR_MATRIX,m),"backdrop-matrix") ||
                    failed(color.p->SetValue(D2D1_PROPERTY_PRECISION,D2D1_BUFFER_PRECISION_32BPC_FLOAT),"backdrop-precision")) goto finish;
            }
            color.p->GetOutput(&adjusted.p);
            if (!color_effect(s->child,adjusted.p,linear.p,srgb.p,&encoded.p)) goto finish;
        }
        encoded.p->GetOutput(&output.p);
        s->child->SetTarget(s->foreground);
        s->child->SetTransform(D2D1_MATRIX_3X2_F{1,0,0,1,0,0});
        s->child->BeginDraw();
        // The capture margin is an input dependency, not visible output. Limit
        // shading to the transformed primitive bounds while preserving the
        // complete sharp/blur inputs required for rays near its edge.
        D2D1_RECT_F output_clip={};
        if(optical) {
            const float xs[4]={rect->left,rect->right,rect->right,rect->left};
            const float ys[4]={rect->top,rect->top,rect->bottom,rect->bottom};
            for(unsigned i=0;i<4;++i) {
                float x=xs[i]*s->child_matrix._11+ys[i]*s->child_matrix._21+s->child_matrix._31;
                float y=xs[i]*s->child_matrix._12+ys[i]*s->child_matrix._22+s->child_matrix._32;
                if(!i)output_clip={x,y,x,y};
                else {output_clip.left=fminf(output_clip.left,x);output_clip.right=fmaxf(output_clip.right,x);
                      output_clip.top=fminf(output_clip.top,y);output_clip.bottom=fmaxf(output_clip.bottom,y);}
            }
            float ax=192/s->dpi_x,ay=192/s->dpi_y;
            output_clip.left-=ax;output_clip.right+=ax;output_clip.top-=ay;output_clip.bottom+=ay;
            s->child->PushAxisAlignedClip(output_clip,D2D1_ANTIALIAS_MODE_ALIASED);
        }
        s->child->DrawImage(output.p,nullptr,nullptr,D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR,D2D1_COMPOSITE_MODE_SOURCE_COPY);
        if(optical)s->child->PopAxisAlignedClip();
        hr=s->child->EndDraw();
        s->child->SetTarget(nullptr);
        if (!failed(hr,"blur-output")) ok=draw_composite(s,1);
    } else if (s->empty) ok=1;
finish:
    destroy(s);
    return ok;
}


// Zero-input GPU image effect used as a brush for conic fills.
#include "conic_effect.h"
// Match the shared SDF shader: interpolate linear, premultiplied stop colors,
// then encode RGB into the sRGB target. Native brushes execute this on GPU.
extern "C" int zenit_d2d_gradient_brush(ID2D1RenderTarget *target, const D2D1_RECT_F *rect,
    const ZenitGradient *gradient, ID2D1Brush **out) {
    *out=nullptr;
    if (!gradient->count || gradient->count>16 || gradient->direction>4 || gradient->extend>2) return 0;
    float w=rect->right-rect->left,h=rect->bottom-rect->top;
    if (!isfinite(w) || !isfinite(h) || w<=0 || h<=0) return 0;
    D2D1_GRADIENT_STOP stops[16];
    for (unsigned i=0;i<gradient->count;++i) {
        const float *c=gradient->colors[i];
        for (unsigned j=0;j<4;++j) if (!isfinite(c[j]) || c[j]<0 || c[j]>1) return 0;
        float p=gradient->positions[i];
        if (!isfinite(p) || p<0 || p>1 || (i && p<stops[i-1].position)) return 0;
        float linear[3];
        for (unsigned j=0;j<3;++j) linear[j]=c[j]<=.04045f ? c[j]/12.92f : powf((c[j]+.055f)/1.055f,2.4f);
        stops[i]={p,{linear[0],linear[1],linear[2],c[3]}};
    }
    Owned<ID2D1GradientStopCollection1> collection;
    ID2D1DeviceContext *dc=static_cast<ID2D1DeviceContext *>(target);
    if(gradient->direction==4)return conic_brush(dc,rect,gradient,stops,out);
    D2D1_EXTEND_MODE extend=gradient->extend==1 ? D2D1_EXTEND_MODE_WRAP : gradient->extend==2 ? D2D1_EXTEND_MODE_MIRROR : D2D1_EXTEND_MODE_CLAMP;
    if (failed(dc->CreateGradientStopCollection(stops,gradient->count,D2D1_COLOR_SPACE_SCRGB,D2D1_COLOR_SPACE_SRGB,
        D2D1_BUFFER_PRECISION_32BPC_FLOAT,extend,D2D1_COLOR_INTERPOLATION_MODE_PREMULTIPLIED,&collection.p),"gradient-stops")) return 0;
    if (gradient->direction==3) {
        for (unsigned i=0;i<2;++i) if (!isfinite(gradient->center[i]) || !isfinite(gradient->radius[i])) return 0;
        D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES props={{rect->left+w*gradient->center[0],rect->top+h*gradient->center[1]},
            {0,0},w*fmaxf(.0001f,gradient->radius[0]),h*fmaxf(.0001f,gradient->radius[1])};
        ID2D1RadialGradientBrush *brush=nullptr;
        if (failed(dc->CreateRadialGradientBrush(props,collection.p,&brush),"radial-gradient")) return 0;
        *out=brush;
    } else {
        D2D1_POINT_2F start={rect->left,rect->top},end=start;
        if (gradient->direction==0) end.x+=w;
        else if (gradient->direction==1) end.y+=h;
        else {
            // t=(u+v)/2 even in a non-square rectangle. A corner-to-corner
            // axis would weight the long side more heavily.
            float gx=.5f/w,gy=.5f/h,denom=gx*gx+gy*gy;
            end.x+=gx/denom; end.y+=gy/denom;
        }
        D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES props={start,end};
        ID2D1LinearGradientBrush *brush=nullptr;
        if (failed(dc->CreateLinearGradientBrush(props,collection.p,&brush),"linear-gradient")) return 0;
        *out=brush;
    }
    return 1;
}
