#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3d11_1.h>
#include <d2d1.h>
#include <initguid.h>
#include <dwrite.h>
#include <dxgi.h>
#include <dxgi1_2.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include "d2d_composite.h"
#include "dwrite_font_ranges.h"

extern void zenit_dwrite_retain_font(void *font);
extern void zenit_dwrite_release_font(void *font);
extern IDWriteTextFormat *zenit_dwrite_create_text_format(const void *font, float size);
extern int zenit_dwrite_draw_fixed_ascii(void *layout, void *target, void *brush,
    const void *font, float x, float y, float baseline, float advance);

extern int zenit_win_caption_button_rect(HWND hwnd, RECT *out);

/* Layouts are independent of the D2D target and survive resize. Keys contain
   every layout input; geometry, tint and layer transforms are applied at draw.
   At most 256 entries of 4096 UTF-8 bytes are retained per window. */
#define TEXT_LAYOUT_CACHE_SIZE 256
#define TEXT_LAYOUT_CACHE_MAX_BYTES 4096
typedef struct ZenitTextLayoutEntry {
    IDWriteTextLayout *layout;
    char *text;
    uint32_t length, weight;
    float size, baseline;
    uint64_t hash, stamp;
    void *font_ref;
    ZenitDWriteFontRanges *font_ranges;
    uint32_t italic;
} ZenitTextLayoutEntry;

typedef struct ZenitBitmapTexture {
    struct ZenitBitmapTexture *next;
    uint32_t id, width, height;
    unsigned char *bgra;
    ID2D1Bitmap *bitmap;
    unsigned char tint[3];
} ZenitBitmapTexture;

typedef struct ZenitShadowKey {
    float w, h, scale, radii[4], blur, offset_x, offset_y, spread, color[4];
    uint32_t inset;
} ZenitShadowKey;
typedef struct ZenitShadowEntry {
    ZenitShadowKey key;
    ID2D1Bitmap *bitmap;
    float pad, width, height;
    float hole[4];
    uint64_t bytes, stamp;
} ZenitShadowEntry;
#define SHADOW_CACHE_SIZE 32
#define SHADOW_CACHE_BYTES UINT64_C(67108864)

typedef struct ZenitFrameTiming {
    uint64_t gpu_execute_us, cpu_frame_us, total_frame_us;
    uint64_t layout_us, render_gen_us, gpu_encode_us;
} ZenitFrameTiming;
typedef struct ZenitTimingQuery {
    ID3D11Query *disjoint, *start, *end;
    uint64_t generation;
    int pending, valid;
    uint64_t sequence;
    ZenitFrameTiming sample;
} ZenitTimingQuery;
typedef struct ZenitTimingStats {
    ZenitFrameTiming last;
    uint64_t gpu_p95_us, cpu_p95_us, total_p95_us, timing_samples, frame_count;
    uint64_t cpu_timing_samples, disjoint_samples, failed_samples, pending_queries, query_supported;
} ZenitTimingStats;
#define TIMING_QUERY_COUNT 8
#define TIMING_SAMPLE_COUNT 120

typedef struct ZenitD3D11Probe {
    HWND hwnd;
    ZenitTimingQuery timing_queries[TIMING_QUERY_COUNT];
    ZenitFrameTiming timings[TIMING_SAMPLE_COUNT], cpu_timings[TIMING_SAMPLE_COUNT], cpu_phases, last_gpu;
    uint64_t timing_generation, timing_frames, timing_sequence, last_gpu_sequence, timing_disjoint, timing_failed;
    unsigned timing_head, timing_len, cpu_timing_head, cpu_timing_len;
    int timing_enabled, gpu_queries_enabled;
    ZenitShadowEntry shadows[SHADOW_CACHE_SIZE];
    uint64_t shadow_bytes, shadow_clock, shadow_hits, shadow_misses;
    ZenitBitmapTexture *textures;
    uint32_t next_texture_id, texture_count;
    uint64_t texture_bytes;
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    ID3D11DeviceContext1 *context1;
    IDXGISwapChain *swapchain;
    ID3D11Texture2D *submitted_copy;
    int retain_submitted, submitted_valid;
    ID3D11RenderTargetView *target;
    ID2D1Factory *d2d_factory;
    void *d2d_device;
    void *luminance;
    void *retained;
    int retained_enabled;
    ID2D1RenderTarget *d2d_target;
    ID2D1SolidColorBrush *d2d_brush;
    IDWriteFactory *dwrite_factory;
    wchar_t *font_family;
    wchar_t *font_locale;
    UINT width;
    UINT height;
    uint32_t frame;
    uint32_t capture_count, capture_tail;
    HRESULT last_present_status;
    int has_present_status;
    int desktop_display_lease;
    IDXGIOutputDuplication *desktop_duplication;
    RECT desktop_output_rect;
    HMONITOR desktop_monitor;
    ZenitTextLayoutEntry text_layouts[TEXT_LAYOUT_CACHE_SIZE];
    uint64_t text_layout_clock, text_layout_hits, text_layout_misses;
    LARGE_INTEGER last_present;
    int driver; /* 1 = hardware, 2 = WARP */
    struct ZenitRectPaint *rects;
    uint32_t rect_count;
    struct ZenitPaintItem *items;
    uint32_t item_count;
    float scale;
    float clear_color[4];
} ZenitD3D11Probe;

unsigned zenit_d3d11_probe_get_luminance(ZenitD3D11Probe *probe, ZenitLuminance *out, unsigned capacity) {
    return probe ? zenit_d2d_luminance_read(probe->luminance,out,capacity) : 0;
}

void zenit_d3d11_probe_get_retained(ZenitD3D11Probe *probe, ZenitRetainedStats *out) {
    zenit_d2d_retained_stats(probe ? probe->retained : NULL,out);
}

void zenit_d3d11_probe_set_retained_enabled(ZenitD3D11Probe *probe, int enabled) {
    if (probe) probe->retained_enabled=enabled!=0;
}

typedef struct ZenitRectPaint {
    float x, y, w, h;
    float r, g, b, a;
} ZenitRectPaint;

typedef struct ZenitPaintItem {
    uint32_t kind; /* 1 = rect, 2 = text, 3/4 = rect clip/pop, 5 = gradient, 6 = ellipse,
                      7/8 = strokes, 9/10 = rounded/ellipse clip, 15 = bitmap,
                      16/17 = outer/inset shadow, 18 = annular arc, 19/20 = vector fill/stroke,
                      21 = immediate backdrop filter, 22 = procedural noise, 23 = polygon clip */
    float x, y, w, h;
    float r, g, b, a;
    float radius;
    float font_size;
    uint32_t font_weight;
    const char *text;
    uint32_t text_length;
    float to_r, to_g, to_b, to_a;
    uint32_t gradient_direction;
    float stroke_width;
    float shadow_radii[4], shadow_blur, shadow_offset_x, shadow_offset_y, shadow_spread;
    ZenitBackdrop backdrop;
    ZenitRetainedInfo retained;
    ZenitGradient gradient;
    ZenitNoise noise;
    void *font_ref;
    float fixed_ascii_advance;
    ZenitDWriteFontRanges *font_ranges;
    uint32_t italic;
} ZenitPaintItem;

size_t zenit_d3d11_probe_item_size(void) { return sizeof(ZenitPaintItem); }

static void free_items(ZenitD3D11Probe *probe) {
    for (uint32_t i = 0; i < probe->item_count; ++i) {
        free((void *)probe->items[i].text);
        if (probe->items[i].font_ref) zenit_dwrite_release_font(probe->items[i].font_ref);
        zenit_dwrite_release_font_ranges(probe->items[i].font_ranges);
        free((void *)probe->items[i].retained.damage);
    }
    free(probe->items);
    probe->items = NULL;
    probe->item_count = 0;
}

static int make_d2d_target(ZenitD3D11Probe *probe) {
    if (!zenit_d2d_create_target(probe->d2d_device,probe->swapchain,&probe->d2d_target)) return 0;
    D2D1_COLOR_F color = {1, 1, 1, 1};
    HRESULT hr = ID2D1RenderTarget_CreateSolidColorBrush(probe->d2d_target,
        &color, NULL, &probe->d2d_brush);
    return SUCCEEDED(hr);
}

static int make_target(ZenitD3D11Probe *probe) {
    ID3D11Texture2D *backbuffer = NULL;
    HRESULT hr = IDXGISwapChain_GetBuffer(probe->swapchain, 0,
        &IID_ID3D11Texture2D, (void **)&backbuffer);
    if (FAILED(hr)) return 0;
    hr = ID3D11Device_CreateRenderTargetView(probe->device,
        (ID3D11Resource *)backbuffer, NULL, &probe->target);
    ID3D11Texture2D_Release(backbuffer);
    return SUCCEEDED(hr);
}

static void release_graphics(ZenitD3D11Probe *probe) {
    if (probe->submitted_copy) ID3D11Texture2D_Release(probe->submitted_copy);
    probe->submitted_copy=NULL; probe->submitted_valid=0;
    if (probe->desktop_duplication) {
        IDXGIOutputDuplication_Release(probe->desktop_duplication);
        probe->desktop_duplication=NULL;
    }
    if (probe->d2d_brush) ID2D1SolidColorBrush_Release(probe->d2d_brush);
    zenit_d2d_luminance_destroy(probe->luminance);
    zenit_d2d_retained_destroy(probe->retained);
    probe->retained=NULL;
    probe->luminance=NULL;
    zenit_d2d_release_target(probe->d2d_target);
    zenit_d2d_release_device(probe->d2d_device);
    if (probe->d2d_factory) ID2D1Factory_Release(probe->d2d_factory);
    if (probe->dwrite_factory) IDWriteFactory_Release(probe->dwrite_factory);
    if (probe->target) ID3D11RenderTargetView_Release(probe->target);
    if (probe->swapchain) IDXGISwapChain_Release(probe->swapchain);
    if (probe->context1) ID3D11DeviceContext1_Release(probe->context1);
    if (probe->context) ID3D11DeviceContext_Release(probe->context);
    if (probe->device) ID3D11Device_Release(probe->device);
    probe->target = NULL;
    probe->d2d_brush = NULL;
    probe->d2d_target = NULL;
    probe->d2d_factory = NULL;
    probe->d2d_device = NULL;
    probe->dwrite_factory = NULL;
    probe->swapchain = NULL;
    probe->context = NULL;
    probe->context1 = NULL;
    probe->device = NULL;
}

// Diagnostic jobs use synthetic RPC input, which does not reset the guest's
// display idle timer. Keep its display awake only for explicit desktop capture.
// All probes are owned by the single UI thread; preserve its prior flags.
static unsigned desktop_display_leases;
static EXECUTION_STATE desktop_previous_execution_state;
static void release_desktop_display(ZenitD3D11Probe *probe) {
    if (probe->desktop_display_lease) {
        probe->desktop_display_lease=0;
        if (--desktop_display_leases==0)
            SetThreadExecutionState(desktop_previous_execution_state|ES_CONTINUOUS);
    }
}

ZenitD3D11Probe *zenit_d3d11_probe_create(void *native_hwnd) {
    if (!native_hwnd) return NULL;
    ZenitD3D11Probe *probe = (ZenitD3D11Probe *)calloc(1, sizeof(*probe));
    if (!probe) return NULL;
    probe->hwnd = (HWND)native_hwnd;
    if (GetEnvironmentVariableW(L"ZENIT_WINDOWS_DESKTOP_CAPTURE",NULL,0)) {
        if (!desktop_display_leases) {
            desktop_previous_execution_state=SetThreadExecutionState(ES_CONTINUOUS|ES_DISPLAY_REQUIRED|ES_SYSTEM_REQUIRED);
            if (!desktop_previous_execution_state) goto failed;
        }
        ++desktop_display_leases;
        probe->desktop_display_lease=1;
        // Zero displacement leaves the guest pointer in place, while giving
        // the guest a native activity event before a desktop-only test job.
        if (GetEnvironmentVariableW(L"ZENIT_WINDOWS_DESKTOP_WAKE_INPUT",NULL,0)) {
            INPUT wake={0}; wake.type=INPUT_MOUSE; wake.mi.dwFlags=MOUSEEVENTF_MOVE;
            fprintf(stderr,"[windows-desktop-wake] native_activity=%u\n",SendInput(1,&wake,sizeof(wake)));
        }
    }
    probe->clear_color[0] = 0.07f;
    probe->clear_color[1] = 0.18f;
    probe->clear_color[2] = 0.34f;
    probe->clear_color[3] = 1.0f;
    RECT rect;
    GetClientRect(probe->hwnd, &rect);
    probe->width = rect.right - rect.left;
    probe->height = rect.bottom - rect.top;
    if (!probe->width || !probe->height) goto failed;

    DXGI_SWAP_CHAIN_DESC desc = {0};
    desc.BufferDesc.Width = probe->width;
    desc.BufferDesc.Height = probe->height;
    desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.OutputWindow = probe->hwnd;
    desc.Windowed = TRUE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE,
        NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0, D3D11_SDK_VERSION,
        &desc, &probe->swapchain, &probe->device, NULL, &probe->context);
    if (SUCCEEDED(hr)) probe->driver = 1;
    if (FAILED(hr)) {
        release_graphics(probe);
        hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_WARP,
            NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0, D3D11_SDK_VERSION,
            &desc, &probe->swapchain, &probe->device, NULL, &probe->context);
        if (SUCCEEDED(hr)) probe->driver = 2;
    }
    if (FAILED(hr) || !make_target(probe)) goto failed;
    // Each window owns a device/swap chain. Keep at most one pending present
    // so the compositor cannot display several old transition states after
    // input has already changed the dialog's visibility.
    IDXGIDevice1 *dxgi_device = NULL;
    hr = ID3D11Device_QueryInterface(probe->device, &IID_IDXGIDevice1,
        (void **)&dxgi_device);
    if (SUCCEEDED(hr)) {
        hr = IDXGIDevice1_SetMaximumFrameLatency(dxgi_device, 1);
        IDXGIDevice1_Release(dxgi_device);
    }
    if (FAILED(hr)) goto failed;
    ID3D11DeviceContext_QueryInterface(probe->context,
        &IID_ID3D11DeviceContext1, (void **)&probe->context1);
    if (!zenit_d2d_create_device(probe->device,&probe->d2d_device,&probe->d2d_factory)) goto failed;
    probe->luminance=zenit_d2d_luminance_create(probe->device,probe->d2d_device);
    if (!probe->luminance) goto failed;
    probe->retained=zenit_d2d_retained_create();
    if (!probe->retained) goto failed;
    probe->retained_enabled=1;
    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,
        &IID_IDWriteFactory, (IUnknown **)&probe->dwrite_factory);
    if (FAILED(hr) || !make_d2d_target(probe)) goto failed;
    {
        IDXGIDevice *device = NULL;
        IDXGIAdapter *adapter = NULL;
        DXGI_ADAPTER_DESC adapter_desc = {0};
        char name[512] = "unknown";
        HRESULT info_hr = ID3D11Device_QueryInterface(probe->device, &IID_IDXGIDevice, (void **)&device);
        if (SUCCEEDED(info_hr)) info_hr = IDXGIDevice_GetAdapter(device, &adapter);
        if (SUCCEEDED(info_hr)) info_hr = IDXGIAdapter_GetDesc(adapter, &adapter_desc);
        if (SUCCEEDED(info_hr)) WideCharToMultiByte(CP_UTF8, 0, adapter_desc.Description, -1,
            name, sizeof(name), NULL, NULL);
        fprintf(stderr, "[d3d11-adapter] driver=%s name=%s feature_level=0x%04x info_result=0x%08lx\n",
            probe->driver == 1 ? "hardware" : "WARP", name,
            (unsigned)ID3D11Device_GetFeatureLevel(probe->device), (unsigned long)info_hr);
        if (adapter) IDXGIAdapter_Release(adapter);
        if (device) IDXGIDevice_Release(device);
    }
    probe->scale = 1.0f;
    return probe;

failed:
    release_desktop_display(probe);
    release_graphics(probe);
    free(probe);
    return NULL;
}

int zenit_d3d11_probe_driver(const ZenitD3D11Probe *probe) {
    return probe ? probe->driver : 0;
}

void zenit_d3d11_probe_set_clear_color(ZenitD3D11Probe *probe,
    float r, float g, float b, float a) {
    if (!probe) return;
    probe->clear_color[0] = r;
    probe->clear_color[1] = g;
    probe->clear_color[2] = b;
    probe->clear_color[3] = a;
}

int zenit_d3d11_probe_rects_supported(const ZenitD3D11Probe *probe) {
    return probe && probe->context1 != NULL;
}

/* Borrowed: the probe owns the device until destroy. */
void *zenit_d3d11_probe_device(const ZenitD3D11Probe *probe) {
    return probe ? probe->device : NULL;
}

int zenit_d3d11_probe_items_supported(const ZenitD3D11Probe *probe) {
    return probe && probe->d2d_target && probe->d2d_brush && probe->dwrite_factory;
}

int zenit_d3d11_probe_set_rects(ZenitD3D11Probe *probe,
    const ZenitRectPaint *rects, uint32_t count, float scale) {
    if (!probe || (count && !rects) || count > 100000 || scale <= 0) return 0;
    ZenitRectPaint *copy = NULL;
    if (count) {
        copy = (ZenitRectPaint *)malloc((size_t)count * sizeof(*copy));
        if (!copy) return 0;
        memcpy(copy, rects, (size_t)count * sizeof(*copy));
    }
    free(probe->rects);
    probe->rects = copy;
    probe->rect_count = count;
    probe->scale = scale;
    return 1;
}

int zenit_d3d11_probe_set_items(ZenitD3D11Probe *probe,
    const ZenitPaintItem *items, uint32_t count, float scale) {
    if (!probe || (count && !items) || count > 100000 || scale <= 0) return 0;
    ZenitPaintItem *copy = count ? (ZenitPaintItem *)calloc(count, sizeof(*copy)) : NULL;
    if (count && !copy) return 0;
    for (uint32_t i = 0; i < count; ++i) {
        copy[i] = items[i];
        copy[i].text = NULL;
        copy[i].font_ref = NULL;
        copy[i].font_ranges = NULL;
        copy[i].retained.damage = NULL;
        if (items[i].font_ranges) {
            if (items[i].kind != 2) goto failed;
            copy[i].font_ranges = items[i].font_ranges;
            zenit_dwrite_retain_font_ranges(copy[i].font_ranges);
        }
        if (items[i].kind == 2 && items[i].font_ref) {
            copy[i].font_ref = items[i].font_ref;
            zenit_dwrite_retain_font(copy[i].font_ref);
        }
        if (items[i].retained.count>128 || (items[i].retained.count && !items[i].retained.damage)) goto failed;
        if (items[i].retained.count) {
            size_t bytes=items[i].retained.count*sizeof(ZenitDamageItem);
            ZenitDamageItem *damage=(ZenitDamageItem *)malloc(bytes);
            if (!damage) goto failed;
            memcpy(damage,items[i].retained.damage,bytes);
            copy[i].retained.damage=damage;
        }
        if (items[i].kind < 1 || items[i].kind > 23) goto failed;
        if (items[i].italic > 1) goto failed;
        if (!isfinite(items[i].fixed_ascii_advance) || items[i].fixed_ascii_advance < 0) goto failed;
        if (items[i].kind == 2 && items[i].fixed_ascii_advance > 0) {
            if (!items[i].text || items[i].text_length > 1048576) goto failed;
            for (uint32_t c = 0; c < items[i].text_length; ++c)
                if ((unsigned char)items[i].text[c] >= 128) goto failed;
        }
        if ((items[i].kind == 11 || items[i].kind == 12 || items[i].kind == 19 || items[i].kind == 20 || items[i].kind == 23) && items[i].text_length % 12 != 0) goto failed;
        if ((items[i].kind == 2 || items[i].kind == 11 || items[i].kind == 12 || items[i].kind == 19 || items[i].kind == 20 || items[i].kind == 23) && items[i].text_length) {
            if (!items[i].text || items[i].text_length > 1048576) goto failed;
            char *text = (char *)malloc((size_t)items[i].text_length + 1);
            if (!text) goto failed;
            memcpy(text, items[i].text, items[i].text_length);
            text[items[i].text_length] = 0;
            copy[i].text = text;
        }
    }
    free_items(probe);
    probe->items = copy;
    probe->item_count = count;
    probe->scale = scale;
    return 1;
failed:
    for (uint32_t i = 0; i < count; ++i) {
        free((void *)copy[i].text);
        if (copy[i].font_ref) zenit_dwrite_release_font(copy[i].font_ref);
        zenit_dwrite_release_font_ranges(copy[i].font_ranges);
        free((void *)copy[i].retained.damage);
    }
    free(copy);
    return 0;
}

#include "rounded_geometry.c"

typedef struct ZenitClipEntry {
    int kind; /* 0 = no-op, 3 = axis clip, 9 = D2D layer */
    ID2D1Layer *layer;
    ID2D1Geometry *geometry;
    void *composite;
    uint32_t serial;
} ZenitClipEntry;

static int pop_clip(ZenitD3D11Probe *probe, ZenitClipEntry *entry) {
    if (entry->composite) return zenit_d2d_composite_end(entry->composite,&probe->d2d_target,1);
    if (entry->kind == 3) ID2D1RenderTarget_PopAxisAlignedClip(probe->d2d_target);
    else if (entry->kind == 9) ID2D1RenderTarget_PopLayer(probe->d2d_target);
    if (entry->layer) ID2D1Layer_Release(entry->layer);
    if (entry->geometry) ID2D1Geometry_Release(entry->geometry);
    return 1;
}

static ID2D1Geometry *shape_clip_geometry(ZenitD3D11Probe *probe,
    const ZenitPaintItem *item) {
    D2D1_RECT_F rect = {item->x, item->y,
        item->x + item->w, item->y + item->h};
    ID2D1Geometry *geometry = NULL;
    if (item->kind == 23) {
        typedef struct { float x, y; uint32_t verb; } ClipPoint;
        const ClipPoint *points = (const ClipPoint *)item->text;
        ID2D1PathGeometry *path = NULL;
        ID2D1GeometrySink *sink = NULL;
        if (!points || !item->text_length || item->text_length % sizeof(ClipPoint) ||
            FAILED(ID2D1Factory_CreatePathGeometry(probe->d2d_factory, &path))) return NULL;
        if (FAILED(ID2D1PathGeometry_Open(path, &sink))) {
            ID2D1PathGeometry_Release(path);
            return NULL;
        }
        ID2D1GeometrySink_SetFillMode(sink, item->gradient_direction == 1 ?
            D2D1_FILL_MODE_ALTERNATE : D2D1_FILL_MODE_WINDING);
        int open = 0, valid = 1;
        for (uint32_t i = 0; i < item->text_length / sizeof(ClipPoint); ++i) {
            D2D1_POINT_2F point = {points[i].x, points[i].y};
            if (!isfinite(point.x) || !isfinite(point.y)) { valid = 0; break; }
            if (points[i].verb == 0 && !open) {
                ID2D1GeometrySink_BeginFigure(sink, point, D2D1_FIGURE_BEGIN_FILLED);
                open = 1;
            } else if (points[i].verb == 1 && open) {
                ID2D1GeometrySink_AddLine(sink, point);
            } else if (points[i].verb == 2 && open) {
                ID2D1GeometrySink_EndFigure(sink, D2D1_FIGURE_END_CLOSED);
                open = 0;
            } else { valid = 0; break; }
        }
        if (open) { ID2D1GeometrySink_EndFigure(sink, D2D1_FIGURE_END_CLOSED); valid = 0; }
        HRESULT result = ID2D1GeometrySink_Close(sink);
        ID2D1GeometrySink_Release(sink);
        if (!valid || FAILED(result)) { ID2D1PathGeometry_Release(path); return NULL; }
        geometry = (ID2D1Geometry *)path;
    } else if ((item->kind == 9 || item->kind == 15) && independent_radii(item)) {
        geometry=rounded_geometry(probe,item,0);
    } else if (item->kind == 9 || item->kind == 15) {
        float radius=fmaxf(0,fminf(item->radius,fminf(item->w,item->h)/2));
        D2D1_ROUNDED_RECT rounded = {rect, radius, radius};
        ID2D1RoundedRectangleGeometry *created = NULL;
        if (SUCCEEDED(ID2D1Factory_CreateRoundedRectangleGeometry(
                probe->d2d_factory, &rounded, &created)))
            geometry = (ID2D1Geometry *)created;
    } else {
        D2D1_ELLIPSE ellipse = {{item->x + item->w * 0.5f,
            item->y + item->h * 0.5f}, item->w * 0.5f, item->h * 0.5f};
        ID2D1EllipseGeometry *created = NULL;
        if (SUCCEEDED(ID2D1Factory_CreateEllipseGeometry(
                probe->d2d_factory, &ellipse, &created)))
            geometry = (ID2D1Geometry *)created;
    }
    return geometry;
}

static ZenitClipEntry push_shape_clip(ZenitD3D11Probe *probe,
    const ZenitPaintItem *item) {
    D2D1_RECT_F rect={item->x,item->y,item->x+item->w,item->y+item->h};
    ID2D1Geometry *geometry=shape_clip_geometry(probe,item);
    ID2D1Layer *layer = NULL;
    if (geometry && SUCCEEDED(ID2D1RenderTarget_CreateLayer(
            probe->d2d_target, NULL, &layer))) {
        D2D1_LAYER_PARAMETERS params = {0};
        D2D1_MATRIX_3X2_F identity = {1, 0, 0, 1, 0, 0};
        params.contentBounds = rect;
        params.geometricMask = geometry;
        params.maskAntialiasMode = D2D1_ANTIALIAS_MODE_PER_PRIMITIVE;
        params.maskTransform = identity;
        params.opacity = 1.0f;
        params.layerOptions = D2D1_LAYER_OPTIONS_NONE;
        ID2D1RenderTarget_PushLayer(probe->d2d_target, &params, layer);
        return (ZenitClipEntry){9, layer, geometry};
    }
    if (layer) ID2D1Layer_Release(layer);
    if (geometry) ID2D1Geometry_Release(geometry);
    // A failed rounded/elliptic mask must not silently become a square clip.
    return (ZenitClipEntry){0, NULL, NULL};
}

static IDWriteTextLayout *acquire_text_layout(ZenitD3D11Probe *probe,
    const ZenitPaintItem *item, float *baseline) {
    float size = item->font_size > 0 ? item->font_size : 14.0f;
    uint64_t hash = UINT64_C(14695981039346656037);
    ZenitTextLayoutEntry *slot = NULL;
    if (item->text_length <= TEXT_LAYOUT_CACHE_MAX_BYTES) {
        for (uint32_t i = 0; i < item->text_length; ++i)
            hash = (hash ^ (unsigned char)item->text[i]) * UINT64_C(1099511628211);
        for (uint32_t i = 0; i < TEXT_LAYOUT_CACHE_SIZE; ++i) {
            ZenitTextLayoutEntry *entry = &probe->text_layouts[i];
            if (entry->layout && entry->hash == hash && entry->length == item->text_length &&
                entry->weight == item->font_weight && entry->size == size && entry->font_ref == item->font_ref &&
                entry->italic == item->italic &&
                zenit_dwrite_font_ranges_equal(entry->font_ranges, item->font_ranges) &&
                !memcmp(entry->text, item->text, item->text_length)) {
                entry->stamp = ++probe->text_layout_clock;
                ++probe->text_layout_hits;
                *baseline = entry->baseline;
                IDWriteTextLayout_AddRef(entry->layout);
                return entry->layout;
            }
            if (!slot || (!entry->layout && slot->layout) ||
                (entry->layout && slot->layout && entry->stamp < slot->stamp)) slot = entry;
        }
    }
    ++probe->text_layout_misses;
    int chars = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        item->text, (int)item->text_length, NULL, 0);
    if (chars <= 0) return NULL;
    wchar_t *wide = (wchar_t *)malloc((size_t)chars * sizeof(wchar_t));
    if (!wide) return NULL;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
            item->text, (int)item->text_length, wide, chars) != chars) {
        free(wide); return NULL;
    }
    IDWriteTextFormat *format = NULL;
    IDWriteTextLayout *layout = NULL;
    HRESULT hr;
    if (item->font_ref) {
        format = zenit_dwrite_create_text_format(item->font_ref, size);
        hr = format ? S_OK : E_FAIL;
    } else hr = IDWriteFactory_CreateTextFormat(probe->dwrite_factory,
        probe->font_family ? probe->font_family : L"Segoe UI", NULL, (DWRITE_FONT_WEIGHT)item->font_weight,
        DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, probe->font_locale ? probe->font_locale : L"en-us", &format);
    if (SUCCEEDED(hr)) {
        IDWriteTextFormat_SetWordWrapping(format, DWRITE_WORD_WRAPPING_NO_WRAP);
        hr = IDWriteFactory_CreateTextLayout(probe->dwrite_factory,
            wide, (UINT32)chars, format, 100000.0f, 100000.0f, &layout);
        IDWriteTextFormat_Release(format);
    }
    if (SUCCEEDED(hr) && item->italic) {
        DWRITE_TEXT_RANGE all = {0, (UINT32)chars};
        hr = IDWriteTextLayout_SetFontStyle(layout, DWRITE_FONT_STYLE_ITALIC, all);
    }
    if (SUCCEEDED(hr) && !zenit_dwrite_apply_font_ranges(layout, item->font_ranges, (const uint16_t *)wide, (uint32_t)chars)) hr = E_INVALIDARG;
    free(wide);
    if (FAILED(hr)) { if (layout) IDWriteTextLayout_Release(layout); return NULL; }
    DWRITE_LINE_METRICS metrics;
    UINT32 actual = 0;
    *baseline = item->font_size * 0.8f;
    if (SUCCEEDED(IDWriteTextLayout_GetLineMetrics(layout, &metrics, 1, &actual)) && actual == 1)
        *baseline = metrics.baseline;
    if (slot) {
        char *copy = (char *)malloc(item->text_length);
        if (copy) {
            memcpy(copy, item->text, item->text_length);
            if (slot->layout) IDWriteTextLayout_Release(slot->layout);
            free(slot->text);
            if (slot->font_ref) zenit_dwrite_release_font(slot->font_ref);
            zenit_dwrite_release_font_ranges(slot->font_ranges);
            *slot = (ZenitTextLayoutEntry){layout, copy, item->text_length,
                item->font_weight, size, *baseline, hash, ++probe->text_layout_clock, item->font_ref, item->font_ranges, item->italic};
            if (slot->font_ref) zenit_dwrite_retain_font(slot->font_ref);
            zenit_dwrite_retain_font_ranges(slot->font_ranges);
            IDWriteTextLayout_AddRef(layout);
        }
    }
    return layout;
}

#ifdef ZENIT_PAINT_CONTRACT
float zenit_d3d11_contract_text_width(ZenitD3D11Probe *probe, const char *text, uint32_t length, float size) {
    if (!probe || !text || !length) return -1;
    ZenitPaintItem item = {0};
    item.text = text; item.text_length = length; item.font_size = size; item.font_weight = 400;
    float baseline;
    IDWriteTextLayout *layout = acquire_text_layout(probe, &item, &baseline);
    if (!layout) return -1;
    DWRITE_TEXT_METRICS metrics;
    HRESULT hr = IDWriteTextLayout_GetMetrics(layout, &metrics);
    IDWriteTextLayout_Release(layout);
    return SUCCEEDED(hr) ? metrics.widthIncludingTrailingWhitespace : -1;
}
float zenit_d3d11_contract_font_width(ZenitD3D11Probe *probe, void *font, const char *text, uint32_t length, float size) {
    if (!probe || !font || !text || !length) return -1;
    ZenitPaintItem item = {0};
    item.text = text; item.text_length = length; item.font_size = size; item.font_weight = 400; item.font_ref = font;
    float baseline;
    IDWriteTextLayout *layout = acquire_text_layout(probe, &item, &baseline);
    if (!layout) return -1;
    DWRITE_TEXT_METRICS metrics;
    HRESULT hr = IDWriteTextLayout_GetMetrics(layout, &metrics);
    IDWriteTextLayout_Release(layout);
    return SUCCEEDED(hr) ? metrics.widthIncludingTrailingWhitespace : -1;
}

#endif

static ZenitBitmapTexture *find_texture(ZenitD3D11Probe *probe, uint32_t id) {
    for (ZenitBitmapTexture *t = probe->textures; t; t = t->next)
        if (t->id == id) return t;
    return NULL;
}

uint32_t zenit_d3d11_texture_load(ZenitD3D11Probe *probe, uint32_t width,
    uint32_t height, const unsigned char *rgba) {
    if (!probe || !rgba || !width || !height || width > 16384 || height > 16384 ||
        probe->texture_count >= 4096 || probe->next_texture_id == UINT32_MAX) return 0;
    uint64_t bytes = (uint64_t)width * height * 4;
    if (bytes > SIZE_MAX || bytes > UINT64_C(536870912) - probe->texture_bytes) return 0;
    ZenitBitmapTexture *t = (ZenitBitmapTexture *)calloc(1, sizeof(*t));
    if (!t) return 0;
    t->bgra = (unsigned char *)malloc((size_t)bytes);
    if (!t->bgra) { free(t); return 0; }
    for (uint64_t i = 0; i < bytes; i += 4) {
        unsigned a = rgba[i+3];
        t->bgra[i] = (unsigned char)((rgba[i+2] * a + 127) / 255);
        t->bgra[i+1] = (unsigned char)((rgba[i+1] * a + 127) / 255);
        t->bgra[i+2] = (unsigned char)((rgba[i] * a + 127) / 255);
        t->bgra[i+3] = (unsigned char)a;
    }
    /* Upload now so loadTexture reports GPU allocation failures to its caller
       rather than return an apparently valid handle that silently draws empty. */
    D2D1_BITMAP_PROPERTIES props = {{DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED}, 96, 96};
    D2D1_SIZE_U size = {width, height};
    if (FAILED(ID2D1RenderTarget_CreateBitmap(probe->d2d_target, size, t->bgra,
            width*4, &props, &t->bitmap))) {
        free(t->bgra); free(t); return 0;
    }
    memset(t->tint, 255, sizeof(t->tint));
    t->id = ++probe->next_texture_id;
    t->width = width; t->height = height;
    t->next = probe->textures; probe->textures = t;
    ++probe->texture_count; probe->texture_bytes += bytes;
    return t->id;
}

void zenit_d3d11_texture_unload(ZenitD3D11Probe *probe, uint32_t id) {
    if (!probe) return;
    ZenitBitmapTexture **link = &probe->textures;
    while (*link && (*link)->id != id) link = &(*link)->next;
    if (!*link) return;
    ZenitBitmapTexture *t = *link; *link = t->next;
    if (t->bitmap) ID2D1Bitmap_Release(t->bitmap);
    --probe->texture_count;
    probe->texture_bytes -= (uint64_t)t->width * t->height * 4;
    free(t->bgra); free(t);
}

int zenit_d3d11_texture_size(ZenitD3D11Probe *probe, uint32_t id, uint32_t *size) {
    ZenitBitmapTexture *t = probe ? find_texture(probe, id) : NULL;
    if (!t || !size) return 0;
    size[0] = t->width; size[1] = t->height; return 1;
}

void zenit_d3d11_texture_stats(ZenitD3D11Probe *probe, uint32_t *count, uint64_t *bytes) {
    *count = probe->texture_count; *bytes = probe->texture_bytes;
}

static void invalidate_texture_bitmaps(ZenitD3D11Probe *probe) {
    for (ZenitBitmapTexture *t = probe->textures; t; t = t->next) {
        if (t->bitmap) ID2D1Bitmap_Release(t->bitmap);
        t->bitmap = NULL;
    }
}

static ID2D1Bitmap *texture_bitmap(ZenitD3D11Probe *probe, ZenitBitmapTexture *t,
    const ZenitPaintItem *item) {
    unsigned char tint[3] = {(unsigned char)(fminf(1,fmaxf(0,item->b))*255+0.5f),
        (unsigned char)(fminf(1,fmaxf(0,item->g))*255+0.5f),
        (unsigned char)(fminf(1,fmaxf(0,item->r))*255+0.5f)};
    if (t->bitmap && !memcmp(tint, t->tint, 3)) return t->bitmap;
    size_t bytes = (size_t)t->width * t->height * 4;
    unsigned char *colored = NULL;
    const unsigned char *pixels = t->bgra;
    if (tint[0] != 255 || tint[1] != 255 || tint[2] != 255) {
        colored = (unsigned char *)malloc(bytes);
        if (!colored) return NULL;
        for (size_t i = 0; i < bytes; i += 4) {
            for (int c = 0; c < 3; ++c) colored[i+c] = (unsigned char)((t->bgra[i+c]*tint[c]+127)/255);
            colored[i+3] = t->bgra[i+3];
        }
        pixels = colored;
    }
    D2D1_BITMAP_PROPERTIES props = {{DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED}, 96, 96};
    D2D1_SIZE_U size = {t->width, t->height};
    ID2D1Bitmap *bitmap = NULL;
    HRESULT hr = ID2D1RenderTarget_CreateBitmap(probe->d2d_target, size, pixels,
        t->width*4, &props, &bitmap);
    free(colored);
    if (FAILED(hr)) return NULL;
    if (t->bitmap) ID2D1Bitmap_Release(t->bitmap);
    t->bitmap = bitmap; memcpy(t->tint, tint, 3);
    return bitmap;
}

static void clear_shadow_cache(ZenitD3D11Probe *probe) {
    for (uint32_t i = 0; i < SHADOW_CACHE_SIZE; ++i) {
        if (probe->shadows[i].bitmap) ID2D1Bitmap_Release(probe->shadows[i].bitmap);
        memset(&probe->shadows[i], 0, sizeof(probe->shadows[i]));
    }
    probe->shadow_bytes = 0;
}

/* Match sdf_primitives.metal's rounded-rect distance and smoothstep coverage.
   Rect-body cutout is independent of fill opacity; inset paints inside it. */
static float rounded_distance(float x, float y, float hw, float hh, const float *radii, float spread) {
    float radius = fmaxf(0, radii[x < 0 ? (y < 0 ? 0 : 3) : (y < 0 ? 1 : 2)] + spread);
    float dx = fabsf(x) - fmaxf(0, hw + spread) + radius;
    float dy = fabsf(y) - fmaxf(0, hh + spread) + radius;
    return fminf(fmaxf(dx,dy), 0) + sqrtf(fmaxf(dx,0)*fmaxf(dx,0) + fmaxf(dy,0)*fmaxf(dy,0)) - radius;
}
static float smooth_coverage(float low, float high, float value) {
    float t = fminf(1, fmaxf(0, (value-low)/(high-low)));
    return t*t*(3-2*t);
}

static ZenitShadowEntry *shadow_bitmap(ZenitD3D11Probe *probe, const ZenitPaintItem *item) {
    ZenitShadowKey key = {0};
    key.w = item->w; key.h = item->h; key.scale = probe->scale;
    memcpy(key.radii, item->shadow_radii, sizeof(key.radii));
    key.blur = item->shadow_blur; key.offset_x = item->shadow_offset_x;
    key.offset_y = item->shadow_offset_y; key.spread = item->shadow_spread;
    key.color[0] = item->r; key.color[1] = item->g; key.color[2] = item->b; key.color[3] = 1;
    /* Opacity belongs to composition, not the cached coverage/color tile.
       Canonicalize tiny inverse-transform roundoff below 1/1024 DIP. */
    float *geometry[] = {&key.w,&key.h,&key.blur,&key.offset_x,&key.offset_y,&key.spread,
        &key.radii[0],&key.radii[1],&key.radii[2],&key.radii[3]};
    for (unsigned i = 0; i < sizeof(geometry)/sizeof(geometry[0]); ++i)
        *geometry[i] = roundf(*geometry[i]*1024)/1024;
    key.inset = item->kind == 17;
    for (uint32_t i = 0; i < SHADOW_CACHE_SIZE; ++i) {
        ZenitShadowEntry *entry = &probe->shadows[i];
        if (entry->bitmap && !memcmp(&entry->key, &key, sizeof(key))) {
            entry->stamp = ++probe->shadow_clock; ++probe->shadow_hits;
            return entry;
        }
    }
    ++probe->shadow_misses;
    if (GetEnvironmentVariableW(L"ZENIT_WINDOWS_FRAME_TIMING",NULL,0))
        fprintf(stderr,"[windows-shadow-miss] w=%.3f h=%.3f r=%.3f blur=%.3f ox=%.3f oy=%.3f spread=%.3f inset=%u\n",key.w,key.h,key.radii[0],key.blur,key.offset_x,key.offset_y,key.spread,key.inset);
    float pad = key.inset ? 1.0f/key.scale :
        ceilf(fmaxf(0,key.blur) + fmaxf(fabsf(key.offset_x),fabsf(key.offset_y)) + fmaxf(0,key.spread) + 1);
    float fw = ceilf((key.w+2*pad)*key.scale), fh = ceilf((key.h+2*pad)*key.scale);
    if (!isfinite(fw) || !isfinite(fh) || fw < 1 || fh < 1 || fw > 16384 || fh > 16384) return NULL;
    UINT width = (UINT)fw, height = (UINT)fh;
    uint64_t bytes = (uint64_t)width*height*4;
    if (bytes > SHADOW_CACHE_BYTES) return NULL;
    ZenitShadowEntry *slot = NULL;
    for (;;) {
        ZenitShadowEntry *oldest = NULL;
        slot = NULL;
        for (uint32_t i = 0; i < SHADOW_CACHE_SIZE; ++i) {
            ZenitShadowEntry *entry = &probe->shadows[i];
            if (!entry->bitmap) slot = entry;
            else if (!oldest || entry->stamp < oldest->stamp) oldest = entry;
        }
        if (slot && probe->shadow_bytes + bytes <= SHADOW_CACHE_BYTES) break;
        if (!oldest) return NULL;
        probe->shadow_bytes -= oldest->bytes;
        ID2D1Bitmap_Release(oldest->bitmap);
        memset(oldest, 0, sizeof(*oldest));
    }
    unsigned char *pixels = (unsigned char *)calloc(1,(size_t)bytes);
    if (!pixels) return NULL;
    float max_radius = fmaxf(fmaxf(key.radii[0],key.radii[1]),fmaxf(key.radii[2],key.radii[3]));
    float cut = fmaxf(0,max_radius) + 1/key.scale;
    if (key.inset) cut += fmaxf(key.blur,1/key.scale) + fmaxf(fabsf(key.offset_x),fabsf(key.offset_y));
    float hole[4] = {pad+cut,pad+cut,pad+key.w-cut,pad+key.h-cut};
    float aa = 0.70710678f/key.scale;
    for (UINT y = 0; y < height; ++y) for (UINT x = 0; x < width; ++x) {
        float local_x = (x+0.5f)/key.scale, local_y = (y+0.5f)/key.scale;
        if (local_x >= hole[0] && local_x <= hole[2] && local_y >= hole[1] && local_y <= hole[3]) continue;
        float px = local_x-pad-key.w/2;
        float py = local_y-pad-key.h/2;
        float body = smooth_coverage(aa, -aa, rounded_distance(px,py,key.w/2,key.h/2,key.radii,0));
        float distance = rounded_distance(px-key.offset_x,py-key.offset_y,key.w/2,key.h/2,key.radii,key.inset ? 0 : key.spread);
        float coverage = key.inset ? body*smooth_coverage(-fmaxf(key.blur,1.0f/key.scale),0,distance) :
            (1-body)*smooth_coverage(key.blur,-key.blur,distance);
        float alpha = fminf(1,fmaxf(0,coverage*key.color[3]));
        size_t i = ((size_t)y*width+x)*4;
        pixels[i] = (unsigned char)(fminf(1,fmaxf(0,key.color[2]))*alpha*255+0.5f);
        pixels[i+1] = (unsigned char)(fminf(1,fmaxf(0,key.color[1]))*alpha*255+0.5f);
        pixels[i+2] = (unsigned char)(fminf(1,fmaxf(0,key.color[0]))*alpha*255+0.5f);
        pixels[i+3] = (unsigned char)(alpha*255+0.5f);
    }
    D2D1_BITMAP_PROPERTIES props = {{DXGI_FORMAT_B8G8R8A8_UNORM,D2D1_ALPHA_MODE_PREMULTIPLIED},96*key.scale,96*key.scale};
    D2D1_SIZE_U size = {width,height};
    ID2D1Bitmap *bitmap = NULL;
    HRESULT hr = ID2D1RenderTarget_CreateBitmap(probe->d2d_target,size,pixels,width*4,&props,&bitmap);
    free(pixels);
    if (FAILED(hr)) return NULL;
    slot->key = key; slot->bitmap = bitmap; slot->pad = pad;
    slot->width = width/key.scale; slot->height = height/key.scale;
    memcpy(slot->hole,hole,sizeof(hole));
    slot->bytes = bytes; slot->stamp = ++probe->shadow_clock;
    probe->shadow_bytes += bytes;
    return slot;
}

static void draw_shadow_region(ZenitD3D11Probe *probe, ZenitShadowEntry *entry,
    const ZenitPaintItem *item, D2D1_RECT_F source) {
    if (source.right <= source.left || source.bottom <= source.top) return;
    float x = item->x-entry->pad, y = item->y-entry->pad;
    D2D1_RECT_F clip = {x+source.left,y+source.top,x+source.right,y+source.bottom};
    D2D1_RECT_F dest = {x,y,x+entry->width,y+entry->height};
    // Crop execution using a clip, keeping the full bitmap sampler domain.
    // Cropping its source rectangle clamps interpolation at each band boundary
    // and produces visible one-pixel seams in fractional-positioned cards.
    ID2D1RenderTarget_PushAxisAlignedClip(probe->d2d_target,&clip,D2D1_ANTIALIAS_MODE_ALIASED);
    ID2D1RenderTarget_DrawBitmap(probe->d2d_target,entry->bitmap,&dest,
        fminf(1,fmaxf(0,item->a)),D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,NULL);
    ID2D1RenderTarget_PopAxisAlignedClip(probe->d2d_target);
}

/* Arc uses an annular sector, with radial flat ends like sdf_arc. A stroked
   centerline would give tangent end caps and different thick-arc coverage. */
static D2D1_POINT_2F arc_point(const ZenitPaintItem *item, float radius, float angle) {
    return (D2D1_POINT_2F){item->x+radius*cosf(angle),item->y+radius*sinf(angle)};
}

static void arc_segments(ID2D1GeometrySink *sink, const ZenitPaintItem *item,
    float radius, float start, float sweep, int clockwise) {
    // Split at pi to avoid endpoint ambiguity for a complete circle.
    unsigned count = (unsigned)ceilf(sweep / 3.14159265358979323846f);
    for (unsigned i=1; i<=count; ++i) {
        float angle = start+(clockwise ? 1 : -1)*sweep*i/count;
        D2D1_ARC_SEGMENT segment = {0};
        segment.point = arc_point(item,radius,angle);
        segment.size = (D2D1_SIZE_F){radius,radius};
        segment.sweepDirection = clockwise ? D2D1_SWEEP_DIRECTION_CLOCKWISE : D2D1_SWEEP_DIRECTION_COUNTER_CLOCKWISE;
        segment.arcSize = D2D1_ARC_SIZE_SMALL;
        ID2D1GeometrySink_AddArc(sink,&segment);
    }
}

static int draw_arc(ZenitD3D11Probe *probe, const ZenitPaintItem *item) {
    const float tau = 6.28318530717958647692f;
    if (!isfinite(item->x) || !isfinite(item->y) || !isfinite(item->radius) || !isfinite(item->stroke_width) ||
        !isfinite(item->to_r) || !isfinite(item->to_g)) return 0;
    float sweep = fminf(tau,fmaxf(0,item->to_g-item->to_r));
    if (sweep>=tau-0.0001f) sweep=tau;
    if (item->radius<=0 || item->stroke_width<=0 || sweep<=0) return 1;
    float start = fmodf(item->to_r,tau);
    float inner = fmaxf(0,item->radius-item->stroke_width);
    ID2D1PathGeometry *geometry = NULL;
    ID2D1GeometrySink *sink = NULL;
    HRESULT hr = ID2D1Factory_CreatePathGeometry(probe->d2d_factory,&geometry);
    if (FAILED(hr)) return 0;
    hr = ID2D1PathGeometry_Open(geometry,&sink);
    if (SUCCEEDED(hr)) {
        ID2D1GeometrySink_SetFillMode(sink,D2D1_FILL_MODE_WINDING);
        ID2D1GeometrySink_BeginFigure(sink,arc_point(item,item->radius,start),D2D1_FIGURE_BEGIN_FILLED);
        arc_segments(sink,item,item->radius,start,sweep,1);
        ID2D1GeometrySink_AddLine(sink,arc_point(item,inner,start+sweep));
        if (inner>0) arc_segments(sink,item,inner,start+sweep,sweep,0);
        ID2D1GeometrySink_EndFigure(sink,D2D1_FIGURE_END_CLOSED);
        hr = ID2D1GeometrySink_Close(sink);
        if (SUCCEEDED(hr)) ID2D1RenderTarget_FillGeometry(probe->d2d_target,
            (ID2D1Geometry *)geometry,(ID2D1Brush *)probe->d2d_brush,NULL);
        ID2D1GeometrySink_Release(sink);
    }
    ID2D1PathGeometry_Release(geometry);
    return SUCCEEDED(hr);
}

static int draw_items(ZenitD3D11Probe *probe) {
    if (!probe->d2d_target || !probe->d2d_brush) return 0;
    zenit_d2d_luminance_begin_frame(probe->luminance);
    ID2D1RenderTarget_SetDpi(probe->d2d_target,
        96.0f * probe->scale, 96.0f * probe->scale);
    ZenitClipEntry clips[128] = {0};
    uint32_t clip_depth = 0, ignored_depth = 0;
    int render_failed = 0;
    typedef struct { D2D1_MATRIX_3X2_F matrix; ID2D1Layer *layer; ID2D1Geometry *mask; void *composite; uint32_t serial; } EffectEntry;
    EffectEntry effects[128] = {0};
    uint32_t effect_depth = 0, ignored_effect_depth = 0;
    uint32_t serial=0;
    uint64_t capture_bytes=0;
    int blended_frame=0, has_backdrop=0;
    for (uint32_t i=0;i<probe->item_count;++i)
        if (probe->items[i].kind==13 && probe->items[i].gradient_direction) blended_frame=1;
        else if (probe->items[i].kind==21) has_backdrop=1;
    float *backdrop_scopes=has_backdrop ? (float *)calloc(probe->item_count,sizeof(float)) : NULL;
    if (has_backdrop && !backdrop_scopes) return 0;
    if (has_backdrop) {
        uint32_t open_effects[128],open_clips[128],ne=0,nc=0;
        for (uint32_t i=0;i<probe->item_count;++i) {
            uint32_t kind=probe->items[i].kind;
            if (kind==13) {
                if (ne==128) { free(backdrop_scopes); return 0; }
                open_effects[ne++]=i;
            } else if (kind==14) { if (ne) --ne; }
            else if (kind==3 || kind==9 || kind==10 || kind==23) {
                if (nc==128) { free(backdrop_scopes); return 0; }
                open_clips[nc++]=i;
            } else if (kind==4) { if (nc) --nc; }
            else if (kind==21) {
                const ZenitBackdrop *glass=&probe->items[i].backdrop;
                float pad=3*glass->radius+2;
                if (glass->optic[0]>0 || glass->optic[2]>0 || glass->surface[3]!=0 ||
                    (glass->tint[3]>.005f && (glass->tint[0]!=1 || glass->tint[1]!=1 || glass->tint[2]!=1)))
                    pad=fmaxf(pad,fmaxf(12,fminf(80,.35f*fminf(probe->items[i].w,probe->items[i].h)+8)));
                for (uint32_t j=0;j<ne;++j) backdrop_scopes[open_effects[j]]=fmaxf(backdrop_scopes[open_effects[j]],pad);
                for (uint32_t j=0;j<nc;++j) backdrop_scopes[open_clips[j]]=fmaxf(backdrop_scopes[open_clips[j]],pad);
            }
        }
    }
    const D2D1_MATRIX_3X2_F identity = {1, 0, 0, 1, 0, 0};
    ID2D1RenderTarget_BeginDraw(probe->d2d_target);
    ID2D1RenderTarget_SetTransform(probe->d2d_target, &identity);
    D2D1_COLOR_F clear = {probe->clear_color[0], probe->clear_color[1], probe->clear_color[2], probe->clear_color[3]};
    ID2D1RenderTarget_Clear(probe->d2d_target, &clear);
    for (uint32_t i = 0; i < probe->item_count; ++i) {
        const ZenitPaintItem *item = &probe->items[i];
        if (item->kind==21) {
            ID2D1Geometry *geometry=rounded_geometry(probe,item,0);
            D2D1_RECT_F rect={item->x,item->y,item->x+item->w,item->y+item->h};
            int ok=geometry && zenit_d2d_backdrop(probe->d2d_device,&probe->d2d_target,
                &rect,geometry,&item->backdrop,&capture_bytes,probe->luminance);
            if (geometry) ID2D1Geometry_Release(geometry);
            if (!ok) { render_failed=1; break; }
            continue;
        }
        if (item->kind == 13) {
            if (effect_depth == 128 || ignored_effect_depth) { ++ignored_effect_depth; continue; }
            EffectEntry entry = {0};
            entry.serial=++serial;
            ID2D1RenderTarget_GetTransform(probe->d2d_target, &entry.matrix);
            const D2D1_MATRIX_3X2_F p = entry.matrix;
            D2D1_MATRIX_3X2_F matrix = {
                item->x*p._11 + item->y*p._21, item->x*p._12 + item->y*p._22,
                item->w*p._11 + item->h*p._21, item->w*p._12 + item->h*p._22,
                item->r*p._11 + item->g*p._21 + p._31, item->r*p._12 + item->g*p._22 + p._32
            };
            int rounded_mask=item->radius>0 || independent_radii(item);
            if (rounded_mask) {
                ZenitPaintItem mask=*item;
                mask.x=item->to_r; mask.y=item->to_g; mask.w=item->to_b; mask.h=item->to_a;
                entry.mask=rounded_geometry(probe,&mask,0);
                if (!entry.mask) { render_failed=1; ++ignored_effect_depth; continue; }
            }
            if (!blended_frame && !(backdrop_scopes && backdrop_scopes[i]) && item->font_weight==0 && item->a>=.999f &&
                fabsf(matrix._11-1)<.00001f && fabsf(matrix._22-1)<.00001f &&
                fabsf(matrix._12)<.00001f && fabsf(matrix._21)<.00001f &&
                item->retained.id!=UINT32_MAX && item->retained.hash &&
                !GetEnvironmentVariableW(L"ZENIT_WINDOWS_DISABLE_RETAINED",NULL,0)) {
                D2D1_RECT_F source={item->to_r,item->to_g,item->to_r+item->to_b,item->to_g+item->to_a};
                int mode=0;
                entry.composite=zenit_d2d_retained_begin(probe->d2d_device,&probe->d2d_target,
                    &matrix,&source,entry.mask,item->a,&capture_bytes,probe->retained,&item->retained,probe->retained_enabled,&mode);
                if (entry.composite) {
                    effects[effect_depth++]=entry;
                    if (mode==1) {
                        unsigned nesting=1;
                        for (uint32_t end=i+1;end<probe->item_count;++end) {
                            if (probe->items[end].kind==13) ++nesting;
                            else if (probe->items[end].kind==14 && --nesting==0) { i=end-1; break; }
                        }
                    }
                    continue;
                }
                if (mode<0) { if (entry.mask) ID2D1Geometry_Release(entry.mask); render_failed=1; break; }
            }
            if (blended_frame || (backdrop_scopes && backdrop_scopes[i])) {
                D2D1_RECT_F source={item->to_r,item->to_g,item->to_r+item->to_b,item->to_g+item->to_a};
                entry.composite=zenit_d2d_composite_begin_padded(probe->d2d_device,&probe->d2d_target,
                    &matrix,&source,entry.mask,item->a,item->gradient_direction,
                    // Glass must sample the pixels behind its opacity ancestors.
                    // Seed normal groups with that backdrop, then interpolate
                    // their completed image once at group opacity. A native
                    // PushLayer exposes a transparent intermediate to capture.
                    item->font_weight==1 || (backdrop_scopes && backdrop_scopes[i] && !item->gradient_direction),
                    &capture_bytes,backdrop_scopes ? backdrop_scopes[i] : 0);
                if (!entry.composite) {
                    if (entry.mask) ID2D1Geometry_Release(entry.mask);
                    render_failed=1; break;
                }
                effects[effect_depth++]=entry;
                continue;
            }
            if ((item->a < 0.999f || rounded_mask) && FAILED(ID2D1RenderTarget_CreateLayer(probe->d2d_target, NULL, &entry.layer))) {
                if (entry.mask) ID2D1Geometry_Release(entry.mask);
                render_failed=1;
                ++ignored_effect_depth;
                continue;
            }
            D2D1_LAYER_PARAMETERS params = {0};
            /* PushLayer interprets bounds in the current parent frame. The
               body geometry is still in the source frame; transform all four
               corners before allocating/clipping the opacity layer. */
            float xs[4] = {item->to_r, item->to_r + item->to_b, item->to_r, item->to_r + item->to_b};
            float ys[4] = {item->to_g, item->to_g, item->to_g + item->to_a, item->to_g + item->to_a};
            for (int corner = 0; corner < 4; ++corner) {
                float x = item->x * xs[corner] + item->w * ys[corner] + item->r;
                float y = item->y * xs[corner] + item->h * ys[corner] + item->g;
                if (!corner) params.contentBounds = (D2D1_RECT_F){x, y, x, y};
                else {
                    if (x < params.contentBounds.left) params.contentBounds.left = x;
                    if (x > params.contentBounds.right) params.contentBounds.right = x;
                    if (y < params.contentBounds.top) params.contentBounds.top = y;
                    if (y > params.contentBounds.bottom) params.contentBounds.bottom = y;
                }
            }
            params.maskAntialiasMode = D2D1_ANTIALIAS_MODE_PER_PRIMITIVE;
            params.maskTransform = rounded_mask ? (D2D1_MATRIX_3X2_F){item->x,item->y,item->w,item->h,item->r,item->g} : identity;
            params.geometricMask=entry.mask;
            params.opacity = item->a;
            if (entry.layer) ID2D1RenderTarget_PushLayer(probe->d2d_target, &params, entry.layer);
            ID2D1RenderTarget_SetTransform(probe->d2d_target, &matrix);
            effects[effect_depth++] = entry;
            continue;
        }
        if (item->kind == 14) {
            if (ignored_effect_depth) { --ignored_effect_depth; continue; }
            if (effect_depth) {
                EffectEntry entry = effects[--effect_depth];
                if (entry.composite && !zenit_d2d_composite_end(entry.composite,&probe->d2d_target,1)) render_failed=1;
                ID2D1RenderTarget_SetTransform(probe->d2d_target, &entry.matrix);
                if (entry.layer) {
                    ID2D1RenderTarget_PopLayer(probe->d2d_target);
                    ID2D1Layer_Release(entry.layer);
                }
                if (entry.mask) ID2D1Geometry_Release(entry.mask);
            }
            continue;
        }
        if (item->kind == 3 || item->kind == 9 || item->kind == 10 || item->kind == 23) {
            if (clip_depth == 128 || ignored_depth) { ++ignored_depth; continue; }
            if (item->kind == 3) {
                D2D1_RECT_F clip = {item->x, item->y,
                    item->x + item->w, item->y + item->h};
                ID2D1RenderTarget_PushAxisAlignedClip(probe->d2d_target, &clip,
                    D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
                clips[clip_depth] = (ZenitClipEntry){3, NULL, NULL};
            } else {
                if (blended_frame || (backdrop_scopes && backdrop_scopes[i])) {
                    ID2D1Geometry *geometry=shape_clip_geometry(probe,item);
                    D2D1_MATRIX_3X2_F matrix;
                    ID2D1RenderTarget_GetTransform(probe->d2d_target,&matrix);
                    D2D1_RECT_F source={item->x,item->y,item->x+item->w,item->y+item->h};
                    void *capture=geometry ? zenit_d2d_composite_begin_padded(probe->d2d_device,&probe->d2d_target,
                        &matrix,&source,geometry,1,0,1,&capture_bytes,backdrop_scopes ? backdrop_scopes[i] : 0) : NULL;
                    if (geometry) ID2D1Geometry_Release(geometry);
                    if (!capture) { render_failed=1; break; }
                    clips[clip_depth]=(ZenitClipEntry){.kind=9,.composite=capture};
                } else clips[clip_depth] = push_shape_clip(probe, item);
                if (!clips[clip_depth].kind) render_failed=1;
            }
            clips[clip_depth].serial=++serial;
            ++clip_depth;
            continue;
        }
        if (item->kind == 4) {
            if (ignored_depth) { --ignored_depth; continue; }
            if (clip_depth) {
                --clip_depth;
                if (!pop_clip(probe, &clips[clip_depth])) render_failed=1;
            }
            continue;
        }
        if (item->kind == 15 && item->w > 0 && item->h > 0 && item->a > 0) {
            ZenitBitmapTexture *texture = find_texture(probe, item->font_weight);
            ID2D1Bitmap *bitmap = texture ? texture_bitmap(probe, texture, item) : NULL;
            if (!bitmap) continue;
            D2D1_MATRIX_3X2_F parent;
            ID2D1RenderTarget_GetTransform(probe->d2d_target, &parent);
            if (item->font_size != 0) {
                float cs = cosf(item->font_size), sn = sinf(item->font_size);
                float cx = item->x + item->w/2, cy = item->y + item->h/2;
                float tx = cx - cs*cx + sn*cy, ty = cy - sn*cx - cs*cy;
                D2D1_MATRIX_3X2_F rotated = {
                    cs*parent._11 + sn*parent._21, cs*parent._12 + sn*parent._22,
                    -sn*parent._11 + cs*parent._21, -sn*parent._12 + cs*parent._22,
                    tx*parent._11 + ty*parent._21 + parent._31,
                    tx*parent._12 + ty*parent._22 + parent._32};
                ID2D1RenderTarget_SetTransform(probe->d2d_target, &rotated);
            }
            ZenitClipEntry clip = {0};
            if (item->radius > 0) {
                clip = push_shape_clip(probe, item);
                if (!clip.kind) render_failed=1;
            }
            D2D1_RECT_F dest = {item->x, item->y, item->x+item->w, item->y+item->h};
            ID2D1RenderTarget_DrawBitmap(probe->d2d_target, bitmap, &dest,
                fminf(1,fmaxf(0,item->a)), D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, NULL);
            if (item->radius > 0 && !pop_clip(probe, &clip)) render_failed=1;
            ID2D1RenderTarget_SetTransform(probe->d2d_target, &parent);
            continue;
        }
        if (item->kind == 16 || item->kind == 17) {
            if (item->a <= 0 || item->w <= 0 || item->h <= 0 || (item->kind == 16 && item->shadow_blur <= 0)) continue;
            ZenitShadowEntry *shadow = shadow_bitmap(probe,item);
            if (!shadow) {
                /* Still unwind clips/effects and EndDraw before reporting it. */
                render_failed = 1;
                continue;
            }
            D2D1_MATRIX_3X2_F transform;
            ID2D1RenderTarget_GetTransform(probe->d2d_target,&transform);
            if (fabsf(transform._12) > 0.000001f || fabsf(transform._21) > 0.000001f) {
                // Axis clips use AABBs; rotated/sheared bands would overlap.
                D2D1_RECT_F dest = {item->x-shadow->pad,item->y-shadow->pad,
                    item->x-shadow->pad+shadow->width,item->y-shadow->pad+shadow->height};
                ID2D1RenderTarget_DrawBitmap(probe->d2d_target,shadow->bitmap,&dest,
                    fminf(1,fmaxf(0,item->a)),D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,NULL);
            } else if (shadow->hole[2] > shadow->hole[0] && shadow->hole[3] > shadow->hole[1]) {
                // Avoid sampling/compositing the fully transparent interior of
                // large cards. Four bands retain exactly the same bitmap pixels.
                draw_shadow_region(probe,shadow,item,(D2D1_RECT_F){0,0,shadow->width,shadow->hole[1]});
                draw_shadow_region(probe,shadow,item,(D2D1_RECT_F){0,shadow->hole[3],shadow->width,shadow->height});
                draw_shadow_region(probe,shadow,item,(D2D1_RECT_F){0,shadow->hole[1],shadow->hole[0],shadow->hole[3]});
                draw_shadow_region(probe,shadow,item,(D2D1_RECT_F){shadow->hole[2],shadow->hole[1],shadow->width,shadow->hole[3]});
            } else draw_shadow_region(probe,shadow,item,(D2D1_RECT_F){0,0,shadow->width,shadow->height});
            continue;
        }
        D2D1_COLOR_F color = {item->r, item->g, item->b, item->a};
        ID2D1SolidColorBrush_SetColor(probe->d2d_brush, &color);
        if (item->kind == 1 || item->kind == 7) {
            if (item->w<=0 || item->h<=0) continue;
            if (item->kind==7 || independent_radii(item)) {
                ID2D1Geometry *geometry=rounded_geometry(probe,item,item->kind==7);
                if (geometry) {
                    ID2D1RenderTarget_FillGeometry(probe->d2d_target,geometry,(ID2D1Brush *)probe->d2d_brush,NULL);
                    ID2D1Geometry_Release(geometry);
                } else render_failed=1;
                continue;
            }
            D2D1_RECT_F rect = {item->x, item->y, item->x + item->w, item->y + item->h};
            if (item->radius > 0) {
                float radius=fmaxf(0,fminf(item->radius,fminf(item->w,item->h)/2));
                D2D1_ROUNDED_RECT rounded = {rect, radius, radius};
                ID2D1RenderTarget_FillRoundedRectangle(probe->d2d_target,
                    &rounded, (ID2D1Brush *)probe->d2d_brush);
            } else {
                ID2D1RenderTarget_FillRectangle(probe->d2d_target,
                    &rect, (ID2D1Brush *)probe->d2d_brush);
            }
        } else if ((item->kind == 6 || item->kind == 8) && item->w > 0 && item->h > 0) {
            D2D1_ELLIPSE ellipse = {{item->x + item->w * 0.5f,
                item->y + item->h * 0.5f}, item->w * 0.5f, item->h * 0.5f};
            if (item->kind == 8)
                ID2D1RenderTarget_DrawEllipse(probe->d2d_target, &ellipse,
                    (ID2D1Brush *)probe->d2d_brush, item->stroke_width, NULL);
            else
                ID2D1RenderTarget_FillEllipse(probe->d2d_target, &ellipse,
                    (ID2D1Brush *)probe->d2d_brush);
        } else if ((item->kind == 5 || item->kind == 22) && item->w > 0 && item->h > 0) {
            D2D1_RECT_F rect = {item->x, item->y, item->x + item->w, item->y + item->h};
            ID2D1Brush *brush = NULL;
            if (item->kind==22) {
                float ox=0,oy=0;
                for(uint32_t j=0;j<effect_depth;++j)if(effects[j].composite){float x,y;zenit_d2d_composite_offset(effects[j].composite,&x,&y);ox+=x;oy+=y;}
                if(!zenit_d2d_noise_brush(probe->d2d_target,&rect,&item->noise,&color,probe->frame,ox,oy,&brush)){render_failed=1;continue;}
            } else if (!zenit_d2d_gradient_brush(probe->d2d_target,&rect,&item->gradient,&brush)) { render_failed=1; continue; }
            if (item->gradient.shape==1) {
                D2D1_ELLIPSE ellipse={{item->x+item->w/2,item->y+item->h/2},item->w/2,item->h/2};
                ID2D1RenderTarget_FillEllipse(probe->d2d_target,&ellipse,brush);
            } else if (independent_radii(item)) {
                ID2D1Geometry *geometry=rounded_geometry(probe,item,0);
                if (geometry) {
                    ID2D1RenderTarget_FillGeometry(probe->d2d_target,geometry,brush,NULL);
                    ID2D1Geometry_Release(geometry);
                } else render_failed=1;
            } else if (item->radius > 0) {
                float radius=fmaxf(0,fminf(item->radius,fminf(item->w,item->h)/2));
                D2D1_ROUNDED_RECT rounded = {rect, radius, radius};
                ID2D1RenderTarget_FillRoundedRectangle(probe->d2d_target,&rounded,brush);
            } else ID2D1RenderTarget_FillRectangle(probe->d2d_target,&rect,brush);
            ID2D1Brush_Release(brush);
        } else if (item->kind == 18) {
            if (!draw_arc(probe,item)) render_failed = 1;
        } else if ((item->kind == 11 || item->kind == 12 || item->kind == 19 || item->kind == 20) && item->text && item->text_length) {
            typedef struct { float x, y; uint32_t verb; } PathPoint;
            const PathPoint *points = (const PathPoint *)item->text;
            ID2D1PathGeometry *geometry = NULL;
            ID2D1GeometrySink *sink = NULL;
            int filled = item->kind == 12 || item->kind == 19;
            if (FAILED(ID2D1Factory_CreatePathGeometry(probe->d2d_factory, &geometry))) { render_failed=1; continue; }
            if (SUCCEEDED(ID2D1PathGeometry_Open(geometry, &sink))) {
                ID2D1GeometrySink_SetFillMode(sink, item->gradient_direction == 1 ? D2D1_FILL_MODE_ALTERNATE : D2D1_FILL_MODE_WINDING);
                int open = 0;
                for (uint32_t j = 0; j < item->text_length / sizeof(PathPoint); ++j) {
                    if (!isfinite(points[j].x) || !isfinite(points[j].y)) { render_failed=1; break; }
                    D2D1_POINT_2F point = {points[j].x, points[j].y};
                    if (points[j].verb == 0) {
                        if (open) ID2D1GeometrySink_EndFigure(sink, D2D1_FIGURE_END_OPEN);
                        ID2D1GeometrySink_BeginFigure(sink, point, filled ? D2D1_FIGURE_BEGIN_FILLED : D2D1_FIGURE_BEGIN_HOLLOW);
                        open = 1;
                    } else if (points[j].verb == 1 && open) {
                        ID2D1GeometrySink_AddLine(sink, point);
                    } else if (points[j].verb == 2 && open) {
                        ID2D1GeometrySink_EndFigure(sink, D2D1_FIGURE_END_CLOSED);
                        open = 0;
                    } else if (points[j].verb == 10 && open && j+1 < item->text_length/sizeof(PathPoint) &&
                        points[j+1].verb==1 && isfinite(points[j+1].x) && isfinite(points[j+1].y)) {
                        D2D1_QUADRATIC_BEZIER_SEGMENT segment = {point,{points[j+1].x,points[j+1].y}};
                        ID2D1GeometrySink_AddQuadraticBezier(sink,&segment);
                        ++j;
                    } else if (points[j].verb == 11 && open && j+2 < item->text_length/sizeof(PathPoint) &&
                        points[j+1].verb==1 && points[j+2].verb==1 && isfinite(points[j+1].x) && isfinite(points[j+1].y) &&
                        isfinite(points[j+2].x) && isfinite(points[j+2].y)) {
                        D2D1_BEZIER_SEGMENT segment = {point,{points[j+1].x,points[j+1].y},{points[j+2].x,points[j+2].y}};
                        ID2D1GeometrySink_AddBezier(sink,&segment);
                        j+=2;
                    } else {
                        render_failed=1;
                    }
                }
                if (open) ID2D1GeometrySink_EndFigure(sink, D2D1_FIGURE_END_OPEN);
                if (SUCCEEDED(ID2D1GeometrySink_Close(sink))) {
                    if (filled) {
                        ID2D1Brush *gradient_brush = NULL;
                        ID2D1Brush *brush = (ID2D1Brush *)probe->d2d_brush;
                        int drawable = 1;
                        if (item->gradient.count) {
                            D2D1_RECT_F bounds;
                            if (FAILED(ID2D1PathGeometry_GetBounds(geometry,NULL,&bounds))) {
                                render_failed=1;
                            } else if (bounds.right<=bounds.left || bounds.bottom<=bounds.top) {
                                // Empty fills have no gradient domain and no
                                // pixels; they must not reject the whole frame.
                                drawable=0;
                            } else if (!zenit_d2d_gradient_brush(probe->d2d_target,&bounds,&item->gradient,&gradient_brush)) {
                                render_failed=1;
                            } else {
                                ID2D1Brush_SetOpacity(gradient_brush,item->a);
                                brush=gradient_brush;
                            }
                        }
                        if (drawable && !render_failed) ID2D1RenderTarget_FillGeometry(probe->d2d_target, (ID2D1Geometry *)geometry, brush, NULL);
                        if (gradient_brush) ID2D1Brush_Release(gradient_brush);
                    } else {
                        ID2D1StrokeStyle *stroke = NULL;
                        D2D1_STROKE_STYLE_PROPERTIES props = {0};
                        props.startCap = props.endCap = props.dashCap = item->kind == 20 ? D2D1_CAP_STYLE_FLAT : D2D1_CAP_STYLE_ROUND;
                        props.lineJoin = item->kind != 20 || item->font_weight == 2 ? D2D1_LINE_JOIN_ROUND :
                            (item->font_weight == 1 ? D2D1_LINE_JOIN_BEVEL : D2D1_LINE_JOIN_MITER_OR_BEVEL);
                        props.miterLimit = item->kind == 20 ? 4 : 10;
                        if (SUCCEEDED(ID2D1Factory_CreateStrokeStyle(probe->d2d_factory, &props, NULL, 0, &stroke)))
                            ID2D1RenderTarget_DrawGeometry(probe->d2d_target, (ID2D1Geometry *)geometry, (ID2D1Brush *)probe->d2d_brush, item->stroke_width, stroke);
                        else render_failed=1;
                        if (stroke) ID2D1StrokeStyle_Release(stroke);
                    }
                } else render_failed=1;
                ID2D1GeometrySink_Release(sink);
            } else render_failed=1;
            ID2D1PathGeometry_Release(geometry);
        } else if (item->kind == 2 && item->text && item->text_length) {
            float baseline;
            IDWriteTextLayout *layout = acquire_text_layout(probe, item, &baseline);
            if (!layout) { render_failed = 1; continue; }
            if (item->fixed_ascii_advance > 0) {
                if (!zenit_dwrite_draw_fixed_ascii(layout, probe->d2d_target, probe->d2d_brush,
                    item->font_ref, item->x, item->y, baseline, item->fixed_ascii_advance)) render_failed = 1;
            } else {
                D2D1_POINT_2F origin = {item->x, item->y - baseline};
                ID2D1RenderTarget_DrawTextLayout(probe->d2d_target, origin,
                    layout, (ID2D1Brush *)probe->d2d_brush,
                    D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
            }
            IDWriteTextLayout_Release(layout);
        }
    }
    // Unwind in actual push order, including a failure inside nested captures.
    while (effect_depth || clip_depth) {
        if (clip_depth && (!effect_depth || clips[clip_depth-1].serial>effects[effect_depth-1].serial)) {
            ZenitClipEntry entry=clips[--clip_depth];
            if (entry.composite) zenit_d2d_composite_end(entry.composite,&probe->d2d_target,0);
            else if (!pop_clip(probe,&entry)) render_failed=1;
            continue;
        }
        EffectEntry entry = effects[--effect_depth];
        if (entry.composite) zenit_d2d_composite_end(entry.composite,&probe->d2d_target,0);
        ID2D1RenderTarget_SetTransform(probe->d2d_target, &entry.matrix);
        if (entry.layer) {
            ID2D1RenderTarget_PopLayer(probe->d2d_target);
            ID2D1Layer_Release(entry.layer);
        }
        if (entry.mask) ID2D1Geometry_Release(entry.mask);
    }
    HRESULT draw_result = ID2D1RenderTarget_EndDraw(probe->d2d_target,NULL,NULL);
    free(backdrop_scopes);
    return !render_failed && SUCCEEDED(draw_result);
}

void zenit_d3d11_probe_retain_submitted(ZenitD3D11Probe *probe, int enabled) {
    probe->retain_submitted=enabled!=0;
    probe->submitted_valid=0;
    if (!enabled && probe->submitted_copy) {
        ID3D11Texture2D_Release(probe->submitted_copy);
        probe->submitted_copy=NULL;
    }
}
static int retain_submitted_frame(ZenitD3D11Probe *probe) {
    ID3D11Texture2D *back=NULL;
    probe->submitted_valid=0;
    if (FAILED(IDXGISwapChain_GetBuffer(probe->swapchain,0,&IID_ID3D11Texture2D,(void **)&back))) return 0;
    D3D11_TEXTURE2D_DESC desc;
    ID3D11Texture2D_GetDesc(back,&desc);
    if (probe->submitted_copy) {
        D3D11_TEXTURE2D_DESC old;
        ID3D11Texture2D_GetDesc(probe->submitted_copy,&old);
        if (old.Width!=desc.Width || old.Height!=desc.Height || old.Format!=desc.Format) {
            ID3D11Texture2D_Release(probe->submitted_copy);
            probe->submitted_copy=NULL;
        }
    }
    if (!probe->submitted_copy) {
        desc.Usage=D3D11_USAGE_DEFAULT; desc.BindFlags=0;
        desc.CPUAccessFlags=0; desc.MiscFlags=0;
        if (FAILED(ID3D11Device_CreateTexture2D(probe->device,&desc,NULL,&probe->submitted_copy))) {
            ID3D11Texture2D_Release(back);
            return 0;
        }
    }
    ID3D11DeviceContext_CopyResource(probe->context,(ID3D11Resource *)probe->submitted_copy,(ID3D11Resource *)back);
    ID3D11Texture2D_Release(back);
    return 1;
}
static int capture_texture_bmp(ZenitD3D11Probe *probe, const wchar_t *path, ID3D11Texture2D *source);
static int capture_current_bmp(ZenitD3D11Probe *probe, const wchar_t *path);

#include "desktop_capture.c"

// Read-only desktop observer for the D3D12 renderer. It owns no swap chain,
// render target or D2D state; D3D11 is used only for DXGI desktop duplication.
void *zenit_windows_desktop_observer_create(void *hwnd) {
    if (!hwnd || !IsWindow((HWND)hwnd)) return NULL;
    ZenitD3D11Probe *p=(ZenitD3D11Probe *)calloc(1,sizeof(*p));
    if (!p) return NULL;
    p->hwnd=(HWND)hwnd;
    D3D_FEATURE_LEVEL level;
    HRESULT hr=D3D11CreateDevice(NULL,D3D_DRIVER_TYPE_HARDWARE,NULL,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,NULL,0,D3D11_SDK_VERSION,
        &p->device,&level,&p->context);
    if (FAILED(hr)) { free(p); return NULL; }
    if (!desktop_display_leases) {
        desktop_previous_execution_state=SetThreadExecutionState(ES_CONTINUOUS|ES_DISPLAY_REQUIRED|ES_SYSTEM_REQUIRED);
        if (!desktop_previous_execution_state) {
            ID3D11DeviceContext_Release(p->context); ID3D11Device_Release(p->device); free(p); return NULL;
        }
    }
    ++desktop_display_leases; p->desktop_display_lease=1;
    if (GetEnvironmentVariableW(L"ZENIT_WINDOWS_DESKTOP_WAKE_INPUT",NULL,0)) {
        INPUT wake={0}; wake.type=INPUT_MOUSE; wake.mi.dwFlags=MOUSEEVENTF_MOVE;
        SendInput(1,&wake,sizeof(wake));
    }
    return p;
}
void zenit_windows_desktop_observer_destroy(void *observer) {
    ZenitD3D11Probe *p=(ZenitD3D11Probe *)observer;
    if (!p) return;
    if (p->desktop_duplication) IDXGIOutputDuplication_Release(p->desktop_duplication);
    ID3D11DeviceContext_Release(p->context); ID3D11Device_Release(p->device);
    release_desktop_display(p); free(p);
}
long long zenit_windows_desktop_observer_clock(void) {
    LARGE_INTEGER now; return QueryPerformanceCounter(&now)?now.QuadPart:0;
}
int zenit_windows_desktop_observer_capture(void *observer,unsigned index,unsigned serial,long long before) {
    ZenitD3D11Probe *p=(ZenitD3D11Probe *)observer;
    if (!p || !before || !serial || serial>0xffffff) return 0;
    p->frame=serial;
    return capture_desktop_bmp(p,index,before);
}

/* Optional bounded capture of the frames actually submitted for presentation.
   This does not advance Cx or generate fresh paint commands.
   Capture incurs GPU readback/disk cost; use a separate uncaptured run for pacing. */
static void trace_presented_frame(ZenitD3D11Probe *probe) {
    wchar_t directory[MAX_PATH], path[MAX_PATH];
    DWORD length = GetEnvironmentVariableW(L"ZENIT_WINDOWS_FRAME_CAPTURE_DIR", directory, MAX_PATH);
    if (!length || length >= MAX_PATH - 40 || probe->capture_count >= 256) return;
    int animated = 0;
    for (uint32_t i = 0; i < probe->item_count; ++i)
        if (probe->items[i].kind == 13 && probe->items[i].a < 0.999f) animated = 1;
    if (animated) probe->capture_tail = 2;
    if (!animated && probe->capture_count && !probe->capture_tail) return;
    if (!animated && probe->capture_tail) --probe->capture_tail;
    swprintf(path, MAX_PATH, L"%ls\\frame-%04u.bmp", directory, probe->capture_count++);
    capture_current_bmp(probe, path);
    fprintf(stderr, "[windows-capture] index=%u scale=%.3f frame_serial=%u", probe->capture_count - 1, probe->scale,probe->frame);
    D2D1_MATRIX_3X2_F matrix={1,0,0,1,0,0}, parents[128];
    float opacity=1, parent_opacity[128];
    unsigned depth=0;
    for (uint32_t i = 0; i < probe->item_count; ++i) {
        const ZenitPaintItem *it = &probe->items[i];
        if (it->kind == 13) {
            fprintf(stderr, " layer=(%.3f,%.3f,%.3f,%.3f,%.4f)",
                it->x*it->to_r + it->w*it->to_g + it->r,
                it->y*it->to_r + it->h*it->to_g + it->g,
                it->x*it->to_b + it->w*it->to_a,
                it->y*it->to_b + it->h*it->to_a, it->a);
            if (depth<128) {
                const D2D1_MATRIX_3X2_F p=matrix;
                parent_opacity[depth]=opacity;
                opacity*=it->a;
                parents[depth++]=p;
                matrix=(D2D1_MATRIX_3X2_F){
                    it->x*p._11+it->y*p._21,it->x*p._12+it->y*p._22,
                    it->w*p._11+it->h*p._21,it->w*p._12+it->h*p._22,
                    it->r*p._11+it->g*p._21+p._31,it->r*p._12+it->g*p._22+p._32};
            }
        } else if (it->kind==14 && depth) { matrix=parents[--depth]; opacity=parent_opacity[depth]; }
        else if (it->kind==21) {
            const float *m=it->backdrop.matrix;
            D2D1_MATRIX_3X2_F world={m[0]*matrix._11+m[1]*matrix._21,m[0]*matrix._12+m[1]*matrix._22,
                m[2]*matrix._11+m[3]*matrix._21,m[2]*matrix._12+m[3]*matrix._22,
                m[4]*matrix._11+m[5]*matrix._21+matrix._31,m[4]*matrix._12+m[5]*matrix._22+matrix._32};
            fprintf(stderr," glass=(%.3f,%.3f,%.3f,%.3f,%.4f,%u)",
                it->x*world._11+it->y*world._21+world._31,it->x*world._12+it->y*world._22+world._32,
                it->w*world._11+it->h*world._21,it->w*world._12+it->h*world._22,opacity,it->backdrop.owner_id);
        }
        else if (it->kind==1 && it->w>200 && it->h>500 && it->r>.95f && it->g>.95f && it->b>.95f) {
            // Large light bodies (Sheet fixture): expose current composed
            // geometry so the audit can compare pixels without a query RPC.
            fprintf(stderr," body=(%.3f,%.3f,%.3f,%.3f,%.4f)",
                it->x*matrix._11+it->y*matrix._21+matrix._31,
                it->x*matrix._12+it->y*matrix._22+matrix._32,
                it->w*matrix._11+it->h*matrix._21,
                it->w*matrix._12+it->h*matrix._22, opacity*it->a);
        }
    }
    fprintf(stderr, "\n");
}

#include "gpu_timing.c"

static int render_frame(ZenitD3D11Probe *probe, int present) {
    if (!probe) return 0;
    const int trace_timing=GetEnvironmentVariableW(L"ZENIT_WINDOWS_FRAME_TIMING",NULL,0)!=0;
    LARGE_INTEGER render_start, draw_end;
    QueryPerformanceCounter(&render_start);
    RECT rect;
    GetClientRect(probe->hwnd, &rect);
    UINT width = rect.right - rect.left;
    UINT height = rect.bottom - rect.top;
    if (!width || !height) return 1;
    if (width != probe->width || height != probe->height) {
        probe->submitted_valid=0;
        ID3D11DeviceContext_OMSetRenderTargets(probe->context, 0, NULL, NULL);
        invalidate_texture_bitmaps(probe);
        clear_shadow_cache(probe);
        if (probe->d2d_brush) { ID2D1SolidColorBrush_Release(probe->d2d_brush); probe->d2d_brush = NULL; }
        if (probe->d2d_target) { zenit_d2d_release_target(probe->d2d_target); probe->d2d_target = NULL; }
        if (probe->target) {
            ID3D11RenderTargetView_Release(probe->target);
            probe->target = NULL;
        }
        if (FAILED(IDXGISwapChain_ResizeBuffers(probe->swapchain, 0,
                width, height, DXGI_FORMAT_UNKNOWN, 0))) return 0;
        probe->width = width;
        probe->height = height;
        if (!make_target(probe) || !make_d2d_target(probe)) return 0;
    }
    if (!probe->target) return 0;
    ZenitTimingQuery *timing = present ? timing_begin(probe) : NULL;
    ID3D11DeviceContext_OMSetRenderTargets(probe->context, 1,
        &probe->target, NULL);
    ID3D11DeviceContext_ClearRenderTargetView(probe->context, probe->target,
        probe->clear_color);
    if (probe->item_count) {
        if (!draw_items(probe)) { timing_end(probe,timing,0); return 0; }
    } else if (probe->context1) {
        for (uint32_t i = 0; i < probe->rect_count; ++i) {
            ZenitRectPaint paint = probe->rects[i];
            D3D11_RECT region = {
                (LONG)(paint.x * probe->scale),
                (LONG)(paint.y * probe->scale),
                (LONG)((paint.x + paint.w) * probe->scale),
                (LONG)((paint.y + paint.h) * probe->scale),
            };
            if (region.left < 0) region.left = 0;
            if (region.top < 0) region.top = 0;
            if (region.right > (LONG)width) region.right = (LONG)width;
            if (region.bottom > (LONG)height) region.bottom = (LONG)height;
            if (region.right <= region.left || region.bottom <= region.top) continue;
            const float rgba[4] = {paint.r, paint.g, paint.b, paint.a};
            ID3D11DeviceContext1_ClearView(probe->context1,
                (ID3D11View *)probe->target, rgba, &region, 1);
        }
    }
    /* DWM needs zero-alpha pixels underneath its caption controls. Clearing
       this reserved rectangle after D2D drawing preserves the native controls
       without changing the alpha semantics of ordinary UI/Glass targets. */
    RECT caption;
    int caption_status=zenit_win_caption_button_rect(probe->hwnd,&caption);
    if (caption_status<0 || (caption_status>0 && !probe->context1)) {
        timing_end(probe,timing,0); return 0;
    }
    if (caption_status>0) {
        if (caption.left<0) caption.left=0;
        if (caption.top<0) caption.top=0;
        if (caption.right>(LONG)width) caption.right=(LONG)width;
        if (caption.bottom>(LONG)height) caption.bottom=(LONG)height;
        const float transparent[4]={0,0,0,0};
        if (caption.right>caption.left && caption.bottom>caption.top)
            ID3D11DeviceContext1_ClearView(probe->context1,(ID3D11View *)probe->target,
                transparent,(const D3D11_RECT *)&caption,1);
    }
    timing_end(probe,timing,1);
    ++probe->frame;
    if (!present) return 1;
    QueryPerformanceCounter(&draw_end);
    int retained_ok=probe->retain_submitted ? retain_submitted_frame(probe) : 0;
    LARGE_INTEGER retained_end, capture_end, present_end;
    if (trace_timing) QueryPerformanceCounter(&retained_end);
    unsigned capture_before=probe->capture_count;
    if (GetEnvironmentVariableW(L"ZENIT_WINDOWS_DESKTOP_CAPTURE",NULL,0) &&
        !stamp_desktop_frame(probe)) {
        fprintf(stderr,"[windows-desktop-unavailable] index=%u stage=stamp\n",capture_before);
        return 0;
    }
    trace_presented_frame(probe);
    if (trace_timing) QueryPerformanceCounter(&capture_end);
    LARGE_INTEGER present_not_before;
    QueryPerformanceCounter(&present_not_before);
    HRESULT present_status=IDXGISwapChain_Present(probe->swapchain,1,0);
    if (trace_timing) QueryPerformanceCounter(&present_end);
    int ok=SUCCEEDED(present_status);
    probe->submitted_valid=retained_ok && ok;
    timing_finish_cpu(probe,timing,render_start,draw_end,ok);
    if (!probe->has_present_status || present_status!=probe->last_present_status) {
        fprintf(stderr,"[windows-present-status] frame=%u hr=0x%08lx normal=%d\n",
            probe->frame,(unsigned long)present_status,present_status==S_OK);
        probe->last_present_status=present_status;
        probe->has_present_status=1;
    }
    if (probe->capture_count>capture_before) {
        fprintf(stderr,"[windows-capture-present] index=%u hr=0x%08lx\n",capture_before,(unsigned long)present_status);
        if (GetEnvironmentVariableW(L"ZENIT_WINDOWS_DESKTOP_CAPTURE",NULL,0)) {
            int captured=0;
            if (present_status==S_OK) captured=capture_desktop_bmp(probe,capture_before,present_not_before.QuadPart);
            else fprintf(stderr,"[windows-desktop-unavailable] index=%u stage=present hr=0x%08lx\n",capture_before,(unsigned long)present_status);
            fprintf(stderr,"[windows-desktop-capture] index=%u ok=%d\n",capture_before,captured);
        }
    }
    if (trace_timing) {
        LARGE_INTEGER now, frequency;
        QueryPerformanceCounter(&now);
        QueryPerformanceFrequency(&frequency);
        float opacity = 1.0f;
        for (uint32_t i = 0; i < probe->item_count; ++i)
            if (probe->items[i].kind == 13 && probe->items[i].a < opacity) opacity = probe->items[i].a;
        double dt = probe->last_present.QuadPart ? 1000.0 * (now.QuadPart - probe->last_present.QuadPart) / frequency.QuadPart : 0;
        fprintf(stderr, "[windows-present] frame=%u dt_ms=%.3f opacity=%.4f ok=%d paint_ms=%.3f wait_ms=%.3f layout_hits=%llu layout_misses=%llu shadow_hits=%llu shadow_misses=%llu retain_ms=%.3f capture_ms=%.3f present_ms=%.3f\n",
            probe->frame, dt, opacity, ok,
            1000.0 * (draw_end.QuadPart - render_start.QuadPart) / frequency.QuadPart,
            1000.0 * (now.QuadPart - draw_end.QuadPart) / frequency.QuadPart,
            (unsigned long long)probe->text_layout_hits, (unsigned long long)probe->text_layout_misses,
            (unsigned long long)probe->shadow_hits, (unsigned long long)probe->shadow_misses,
            1000.0 * (retained_end.QuadPart - draw_end.QuadPart) / frequency.QuadPart,
            1000.0 * (capture_end.QuadPart - retained_end.QuadPart) / frequency.QuadPart,
            1000.0 * (present_end.QuadPart - present_not_before.QuadPart) / frequency.QuadPart);
        probe->last_present = now;
    }
    return ok;
}

int zenit_d3d11_probe_render(ZenitD3D11Probe *probe) {
    return render_frame(probe, 1);
}

/* Test-mode callers read the retained submitted surface without rendering.
   Other native callers keep the historical draw-current-items capture path.
   The worker converts the lossless BGRA BMP to PNG on the host. */
int zenit_d3d11_probe_capture_bmp(ZenitD3D11Probe *probe, const wchar_t *path) {
    if (!probe || !path) return 0;
    if (probe->retain_submitted) return probe->submitted_valid && capture_texture_bmp(probe,path,probe->submitted_copy);
    if (!render_frame(probe, 0)) return 0;
    return capture_current_bmp(probe, path);
}

static int capture_current_bmp(ZenitD3D11Probe *probe, const wchar_t *path) {
    return capture_texture_bmp(probe,path,NULL);
}

static int capture_texture_bmp(ZenitD3D11Probe *probe, const wchar_t *path, ID3D11Texture2D *source) {
    ID3D11Texture2D *back = NULL, *staging = NULL;
    HANDLE file = INVALID_HANDLE_VALUE;
    int mapped = 0, created = 0, ok = 0;
    D3D11_MAPPED_SUBRESOURCE pixels = {0};
    if (source) { back=source; ID3D11Texture2D_AddRef(back); }
    else if (FAILED(IDXGISwapChain_GetBuffer(probe->swapchain, 0,
            &IID_ID3D11Texture2D, (void **)&back))) goto done;
    D3D11_TEXTURE2D_DESC desc;
    ID3D11Texture2D_GetDesc(back, &desc);
    if (desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM || !desc.Width || !desc.Height ||
        (uint64_t)desc.Width * desc.Height * 4 > UINT32_MAX - 54) goto done;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.MiscFlags = 0;
    if (FAILED(ID3D11Device_CreateTexture2D(probe->device, &desc, NULL, &staging))) goto done;
    ID3D11DeviceContext_CopyResource(probe->context,
        (ID3D11Resource *)staging, (ID3D11Resource *)back);
    if (FAILED(ID3D11DeviceContext_Map(probe->context, (ID3D11Resource *)staging,
            0, D3D11_MAP_READ, 0, &pixels))) goto done;
    mapped = 1;
    file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) goto done;
    created = 1;
    BITMAPFILEHEADER header = {0};
    BITMAPINFOHEADER info = {0};
    header.bfType = 0x4d42;
    header.bfOffBits = sizeof(header) + sizeof(info);
    header.bfSize = header.bfOffBits + desc.Width * desc.Height * 4;
    info.biSize = sizeof(info);
    info.biWidth = (LONG)desc.Width;
    info.biHeight = -(LONG)desc.Height;
    info.biPlanes = 1;
    info.biBitCount = 32;
    info.biCompression = BI_RGB;
    info.biSizeImage = desc.Width * desc.Height * 4;
    DWORD written;
    if (!WriteFile(file, &header, sizeof(header), &written, NULL) || written != sizeof(header) ||
        !WriteFile(file, &info, sizeof(info), &written, NULL) || written != sizeof(info)) goto done;
    for (UINT y = 0; y < desc.Height; ++y) {
        if (!WriteFile(file, (const BYTE *)pixels.pData + (size_t)y * pixels.RowPitch,
                desc.Width * 4, &written, NULL) || written != desc.Width * 4) goto done;
    }
    ok = 1;
done:
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    if (mapped) ID3D11DeviceContext_Unmap(probe->context, (ID3D11Resource *)staging, 0);
    if (staging) ID3D11Texture2D_Release(staging);
    if (back) ID3D11Texture2D_Release(back);
    if (!ok && created) DeleteFileW(path);
    return ok;
}

#ifdef ZENIT_PAINT_CONTRACT
/* A real caller-created resource retains its device independently of the App. */
void *zenit_d3d11_contract_create_texture(void *handle) {
    if (!handle) return NULL;
    D3D11_TEXTURE2D_DESC desc = {0};
    desc.Width = desc.Height = desc.MipLevels = desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    ID3D11Texture2D *texture = NULL;
    return SUCCEEDED(ID3D11Device_CreateTexture2D((ID3D11Device *)handle,
        &desc, NULL, &texture)) ? texture : NULL;
}
int zenit_d3d11_contract_texture_device(void *resource, void *expected) {
    if (!resource || !expected) return 0;
    ID3D11Device *device = NULL;
    ID3D11Texture2D_GetDevice((ID3D11Texture2D *)resource, &device);
    D3D11_TEXTURE2D_DESC desc;
    ID3D11Texture2D_GetDesc((ID3D11Texture2D *)resource, &desc);
    int valid = device == expected && desc.Width == 1 && desc.Height == 1 &&
        desc.Format == DXGI_FORMAT_R8G8B8A8_UNORM;
    if (device) ID3D11Device_Release(device);
    return valid;
}
void zenit_d3d11_contract_release_texture(void *resource) {
    if (resource) ID3D11Texture2D_Release((ID3D11Texture2D *)resource);
}
void zenit_d3d11_contract_clear_color(ZenitD3D11Probe *probe, float *out) { memcpy(out, probe->clear_color, sizeof(probe->clear_color)); }
void zenit_d3d11_contract_text_stats(ZenitD3D11Probe *probe, uint64_t *out) {
    out[0] = probe->text_layout_hits; out[1] = probe->text_layout_misses;
}
void *zenit_d3d11_contract_last_text_font(ZenitD3D11Probe *probe) {
    for (uint32_t i = probe->item_count; i > 0; --i) if (probe->items[i-1].kind == 2) return probe->items[i-1].font_ref;
    return NULL;
}
int zenit_d3d11_contract_render_font(ZenitD3D11Probe *probe, void *font, const char *text, uint32_t length) {
    ZenitPaintItem item = {0};
    item.kind = 2; item.x = 10; item.y = 60; item.a = 1;
    item.text = text; item.text_length = length; item.font_size = 32; item.font_weight = 400; item.font_ref = font;
    return zenit_d3d11_probe_set_items(probe, &item, 1, 1) && zenit_d3d11_probe_render(probe);
}
#endif

int zenit_d3d11_probe_clear_text(ZenitD3D11Probe *probe) {
    if (!probe) return 0;
    for (uint32_t i = 0; i < TEXT_LAYOUT_CACHE_SIZE; ++i) {
        if (probe->text_layouts[i].layout) IDWriteTextLayout_Release(probe->text_layouts[i].layout);
        free(probe->text_layouts[i].text);
        if (probe->text_layouts[i].font_ref) zenit_dwrite_release_font(probe->text_layouts[i].font_ref);
        zenit_dwrite_release_font_ranges(probe->text_layouts[i].font_ranges);
        memset(&probe->text_layouts[i], 0, sizeof(probe->text_layouts[i]));
    }
    zenit_d2d_retained_destroy(probe->retained);
    probe->retained = zenit_d2d_retained_create();
    return probe->retained != NULL;
}

int zenit_d3d11_probe_set_font_family(ZenitD3D11Probe *probe, const char *family) {
    if (!probe || !family) return 0;
    const char *requested = strcmp(family, "system") == 0 ? "Segoe UI" : family;
    int chars = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, requested, -1, NULL, 0);
    if (chars <= 1) return 0;
    wchar_t *wide = (wchar_t *)malloc((size_t)chars * sizeof(wchar_t));
    if (!wide) return 0;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, requested, -1, wide, chars) != chars) {
        free(wide); return 0;
    }
    // Layout keys do not include the family, so invalidate them on a change.
    for (uint32_t i = 0; i < TEXT_LAYOUT_CACHE_SIZE; ++i) {
        if (probe->text_layouts[i].layout) IDWriteTextLayout_Release(probe->text_layouts[i].layout);
        free(probe->text_layouts[i].text);
        if (probe->text_layouts[i].font_ref) zenit_dwrite_release_font(probe->text_layouts[i].font_ref);
        zenit_dwrite_release_font_ranges(probe->text_layouts[i].font_ranges);
        memset(&probe->text_layouts[i], 0, sizeof(probe->text_layouts[i]));
    }
    // Cached subtree pixels also depend on the default family.
    zenit_d2d_retained_destroy(probe->retained);
    probe->retained = zenit_d2d_retained_create();
    free(probe->font_family);
    probe->font_family = wide;
    return 1;
}

int zenit_d3d11_probe_set_font_locale(ZenitD3D11Probe *probe, const char *locale) {
    if (!probe || !locale) return 0;
    const char *requested = locale;
    int chars = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, requested, -1, NULL, 0);
    if (chars <= 1) return 0;
    wchar_t *wide = (wchar_t *)malloc((size_t)chars * sizeof(wchar_t));
    if (!wide) return 0;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, requested, -1, wide, chars) != chars) {
        free(wide); return 0;
    }
    // Layout keys do not include the locale, so invalidate them on a change.
    for (uint32_t i = 0; i < TEXT_LAYOUT_CACHE_SIZE; ++i) {
        if (probe->text_layouts[i].layout) IDWriteTextLayout_Release(probe->text_layouts[i].layout);
        free(probe->text_layouts[i].text);
        if (probe->text_layouts[i].font_ref) zenit_dwrite_release_font(probe->text_layouts[i].font_ref);
        zenit_dwrite_release_font_ranges(probe->text_layouts[i].font_ranges);
        memset(&probe->text_layouts[i], 0, sizeof(probe->text_layouts[i]));
    }
    // Cached subtree pixels also depend on the default locale.
    zenit_d2d_retained_destroy(probe->retained);
    probe->retained = zenit_d2d_retained_create();
    free(probe->font_locale);
    probe->font_locale = wide;
    return 1;
}

void zenit_d3d11_probe_destroy(ZenitD3D11Probe *probe) {
    if (!probe) return;
    timing_release(probe);
    clear_shadow_cache(probe);
    while (probe->textures) zenit_d3d11_texture_unload(probe, probe->textures->id);
    for (uint32_t i = 0; i < TEXT_LAYOUT_CACHE_SIZE; ++i) {
        if (probe->text_layouts[i].layout) IDWriteTextLayout_Release(probe->text_layouts[i].layout);
        free(probe->text_layouts[i].text);
        if (probe->text_layouts[i].font_ref) zenit_dwrite_release_font(probe->text_layouts[i].font_ref);
        zenit_dwrite_release_font_ranges(probe->text_layouts[i].font_ranges);
    }
    ID3D11DeviceContext_ClearState(probe->context);
    release_graphics(probe);
    free(probe->font_family);
    free(probe->font_locale);
    free(probe->rects);
    free_items(probe);
    release_desktop_display(probe);
    free(probe);
}
