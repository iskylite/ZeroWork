// Included after native queue/texture definitions; render-thread confined.
struct ZenitD12Surface {
    IDXGISwapChain3 *raw; ZenitD12Queue *queue;
    ZenitD12Texture *buffers[16]; uint32_t count;
    DXGI_FORMAT view_format;
    ZenitD12Texture *acquired;
    bool present_pending;
    HWND hwnd;
    IDCompositionDevice *composition;
    IDCompositionTarget *composition_target;
    IDCompositionVisual *composition_root, *composition_parts[4];
    RECT caption_clip;
    bool clip_valid;

};
// A custom frame reserves native DWM caption controls. HWND flip chains cover
// those controls; compose four disjoint strips around their physical rectangle.
// Keep the submitted surface intact so capture and rendering semantics agree.
static void surface_release_composition(ZenitD12Surface *s) {
    if (s->composition_target) s->composition_target->SetRoot(nullptr);
    if (s->composition) s->composition->Commit();
    for (auto part:s->composition_parts) if (part) part->Release();
    if (s->composition_root) s->composition_root->Release();
    if (s->composition_target) s->composition_target->Release();
    if (s->composition) s->composition->Release();
}
static LONG surface_clamp_coordinate(LONG value,LONG low,LONG high) {
    return value<low?low:(value>high?high:value);
}
static HRESULT surface_update_composition(ZenitD12Surface *s) {
    if (!s->composition) return S_OK;
    DXGI_SWAP_CHAIN_DESC1 desc={};
    HRESULT hr=s->raw->GetDesc1(&desc); if (FAILED(hr)) return hr;
    RECT buttons={0,0,0,0},outer; POINT origin={0,0};
    // Only while DWM actually paints caption buttons over this client (the
    // bridge maintains the property); application-painted controls keep the
    // whole surface, otherwise their slots are cut out and left black.
    if (GetPropW(s->hwnd,L"Zenit.DwmCaption")) {
        hr=DwmGetWindowAttribute(s->hwnd,DWMWA_CAPTION_BUTTON_BOUNDS,&buttons,sizeof(buttons));
        if (FAILED(hr) || !GetWindowRect(s->hwnd,&outer) || !ClientToScreen(s->hwnd,&origin)) return E_FAIL;
        OffsetRect(&buttons,outer.left-origin.x,outer.top-origin.y);
        buttons.left=surface_clamp_coordinate(buttons.left,0,(LONG)desc.Width);
        buttons.right=surface_clamp_coordinate(buttons.right,buttons.left,(LONG)desc.Width);
        buttons.top=surface_clamp_coordinate(buttons.top,0,(LONG)desc.Height);
        buttons.bottom=surface_clamp_coordinate(buttons.bottom,buttons.top,(LONG)desc.Height);
    }
    if (s->clip_valid && EqualRect(&buttons,&s->caption_clip)) return S_OK;
    // Clear the redirected HWND content even when rendering is driven directly
    // by the app loop instead of a WM_PAINT invalidation.
    HDC dc=GetDC(s->hwnd);
    if (!dc) return E_FAIL;
    BOOL cleared=buttons.right==buttons.left || buttons.bottom==buttons.top ||
        PatBlt(dc,buttons.left,buttons.top,buttons.right-buttons.left,
            buttons.bottom-buttons.top,BLACKNESS);
    ReleaseDC(s->hwnd,dc);
    if (!cleared) return E_FAIL;
    const float w=(float)desc.Width,h=(float)desc.Height;
    const float l=(float)buttons.left,r=(float)buttons.right,t=(float)buttons.top,b=(float)buttons.bottom;
    const D2D_RECT_F clips[4]={{0,0,w,t},{0,t,l,b},{r,t,w,b},{0,b,w,h}};
    for (unsigned i=0;i<4 && SUCCEEDED(hr);++i) hr=s->composition_parts[i]->SetClip(clips[i]);
    if (SUCCEEDED(hr)) hr=s->composition->Commit();
    if (SUCCEEDED(hr)) { s->caption_clip=buttons; s->clip_valid=true;
        fprintf(stderr,"[d3d12-caption-clip] %ld,%ld,%ld,%ld\n",buttons.left,buttons.top,buttons.right,buttons.bottom); }
    return hr;
}
#ifdef ZENIT_D12_TEST
extern "C" uint32_t zenit_d12_test_texture_allocation_format(ZenitD12Texture *t) {
    return (uint32_t)t->raw->GetDesc().Format;
}
#endif
static void surface_release_buffers(ZenitD12Surface *s) {
    for (uint32_t i=0;i<s->count;++i) {
        zenit_d12_texture_release(s->buffers[i]); s->buffers[i]=nullptr;
    }
}
static int surface_load_buffers(ZenitD12Surface *s) {
    if (s->buffers[0]) return 0;
    for (uint32_t i=0;i<s->count;++i) {
        auto t=(ZenitD12Texture *)calloc(1,sizeof(ZenitD12Texture));
        if (!t) { surface_release_buffers(s); return 2; }
        if (FAILED(s->raw->GetBuffer(i,IID_ID3D12Resource,(void **)&t->raw))) {
            free(t); surface_release_buffers(s); return 2;
        }
        const auto desc=t->raw->GetDesc();
        t->owner=s->queue->owner; InterlockedIncrement(&t->owner->refs);
        t->refs=1; t->dimension=2; t->width=(uint32_t)desc.Width; t->height=desc.Height;
        t->depth=1; t->mips=1; t->samples=1; t->format=s->view_format;
        // Copy source/destination, sampled, and render attachment. The backdrop
        // pipeline samples the main target directly (native Liquid Glass grid
        // banks downsample the whole window), as Metal does on its drawable.
        t->usage=1u|2u|4u|16u;
        s->buffers[i]=t;
    }
    return 0;
}
static int surface_idle(ZenitD12Surface *s,uint32_t timeout) {
    if (s->acquired) return 5;
    // The render-command fence precedes Present. Resize/destruction must also
    // cover work queued by DXGI, so append a fence after the last Present call.
    if (s->present_pending) {
        if (s->queue->last_serial>=UINT64_MAX-1) return 2;
        uint64_t serial=++s->queue->last_serial;
        s->present_pending=false;
#ifdef ZENIT_D12_TEST
        if (s->queue->fail_next_signal) {
            s->queue->fail_next_signal=false; s->queue->signal_failed=true;
        } else
#endif
        s->queue->signal_failed=FAILED(s->queue->raw->Signal(s->queue->fence,serial));
        if (s->queue->signal_failed) return 2; // queue_wait retries this serial.
    }
    int result=zenit_d12_queue_wait(s->queue,s->queue->last_serial,timeout);
    if (result) return result;
    for (uint32_t i=0;i<s->count;++i)
        if (s->buffers[i] && s->buffers[i]->refs!=1) return 5;
    return 0;
}
extern "C" int zenit_d12_surface_create(ZenitD12Queue *q,void *hwnd,uint32_t w,uint32_t h,
    uint32_t format,uint32_t count,ZenitD12Surface **out) {
    if (!out) return 1;
    *out=nullptr;
    if (!q || !IsWindow((HWND)hwnd) || !w || !h || w>16384 || h>16384 || count<2 || count>16 ||
        (format!=DXGI_FORMAT_B8G8R8A8_UNORM && format!=DXGI_FORMAT_B8G8R8A8_UNORM_SRGB &&
         format!=DXGI_FORMAT_R8G8B8A8_UNORM && format!=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB &&
         format!=DXGI_FORMAT_R16G16B16A16_FLOAT)) return 1;
    IDXGIFactory4 *factory=nullptr; IDXGISwapChain1 *chain=nullptr;
    auto s=(ZenitD12Surface *)calloc(1,sizeof(ZenitD12Surface));
    if (!s) return 2;
    s->queue=q; s->count=count; s->hwnd=(HWND)hwnd;
    s->view_format=(DXGI_FORMAT)format;
    // Flip-model allocation is UNORM; RTV/SRV typed views carry sRGB decoding/
    // encoding. Preserve the requested view format across buffer recreation.
    DXGI_FORMAT allocation_format=s->view_format;
    if (allocation_format==DXGI_FORMAT_B8G8R8A8_UNORM_SRGB) allocation_format=DXGI_FORMAT_B8G8R8A8_UNORM;
    if (allocation_format==DXGI_FORMAT_R8G8B8A8_UNORM_SRGB) allocation_format=DXGI_FORMAT_R8G8B8A8_UNORM;
    DXGI_SWAP_CHAIN_DESC1 desc={}; desc.Width=w; desc.Height=h; desc.Format=allocation_format;
    desc.SampleDesc.Count=1; desc.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT|DXGI_USAGE_SHADER_INPUT;
    desc.BufferCount=count; desc.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;
    desc.AlphaMode=DXGI_ALPHA_MODE_IGNORE;
    // Never stretch an older buffer over a resized client (composition: stretch only).
    desc.Scaling=DXGI_SCALING_NONE;
    HRESULT hr=CreateDXGIFactory1(IID_IDXGIFactory4,(void **)&factory);
    const bool custom=GetPropW((HWND)hwnd,L"Zenit.CustomFrame")!=nullptr;
    if (custom) {
        desc.Scaling=DXGI_SCALING_STRETCH;
        desc.SwapEffect=DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
        desc.AlphaMode=DXGI_ALPHA_MODE_PREMULTIPLIED;
        if (SUCCEEDED(hr)) hr=factory->CreateSwapChainForComposition(q->raw,&desc,nullptr,&chain);
        if (SUCCEEDED(hr)) hr=DCompositionCreateDevice(nullptr,__uuidof(IDCompositionDevice),(void **)&s->composition);
        if (SUCCEEDED(hr)) hr=s->composition->CreateTargetForHwnd((HWND)hwnd,FALSE,&s->composition_target);
        if (SUCCEEDED(hr)) hr=s->composition->CreateVisual(&s->composition_root);
        for (unsigned i=0;i<4 && SUCCEEDED(hr);++i) {
            hr=s->composition->CreateVisual(&s->composition_parts[i]);
            if (SUCCEEDED(hr)) hr=s->composition_parts[i]->SetContent(chain);
            if (SUCCEEDED(hr)) hr=s->composition_root->AddVisual(s->composition_parts[i],FALSE,nullptr);
        }
        if (SUCCEEDED(hr)) hr=s->composition_target->SetRoot(s->composition_root);
    } else if (SUCCEEDED(hr)) hr=factory->CreateSwapChainForHwnd(q->raw,(HWND)hwnd,&desc,nullptr,nullptr,&chain);
    if (SUCCEEDED(hr)) hr=chain->QueryInterface(IID_IDXGISwapChain3,(void **)&s->raw);
    if (SUCCEEDED(hr)) hr=factory->MakeWindowAssociation((HWND)hwnd,DXGI_MWA_NO_ALT_ENTER);
    if (SUCCEEDED(hr)) hr=surface_update_composition(s);
    if (chain) chain->Release(); if (factory) factory->Release();
    if (FAILED(hr)) { surface_release_composition(s); if (s->raw) s->raw->Release(); free(s); return 2; }
    int result=surface_load_buffers(s);
    if (result) { surface_release_composition(s); s->raw->Release(); free(s); return result; }
    *out=s; return 0;
}
extern "C" int zenit_d12_surface_resize(ZenitD12Surface *s,uint32_t w,uint32_t h,uint32_t timeout) {
    if (!s || !w || !h || w>16384 || h>16384) return 1;
    int result=surface_idle(s,timeout); if (result) return result;
    surface_release_buffers(s);
    HRESULT hr=s->raw->ResizeBuffers(s->count,w,h,DXGI_FORMAT_UNKNOWN,0);
    // Reload old buffers after a rejected resize; never keep stale wrappers.
    result=surface_load_buffers(s);
    s->clip_valid=false;
    if (SUCCEEDED(hr)) hr=surface_update_composition(s);
    return FAILED(hr)?2:result;
}
extern "C" int zenit_d12_surface_acquire(ZenitD12Surface *s,ZenitD12Texture **out) {
    if (!out) return 1; *out=nullptr;
    if (!s) return 1; if (s->acquired) return 5;
    int result=surface_load_buffers(s); if (result) return result;
    uint32_t index=s->raw->GetCurrentBackBufferIndex(); if (index>=s->count) return 2;
    s->acquired=s->buffers[index]; zenit_d12_texture_retain(s->acquired);
    *out=s->acquired; return 0;
}
extern "C" int zenit_d12_surface_present(ZenitD12Surface *s,ZenitD12Texture *t,uint32_t interval,int *occluded) {
    if (!s || !t || s->acquired!=t || interval>1 || !occluded) return 1;
    *occluded=0;
    HRESULT hr=surface_update_composition(s);
    if (SUCCEEDED(hr)) hr=s->raw->Present(interval,0);
    if (FAILED(hr)) return FAILED(s->queue->owner->raw->GetDeviceRemovedReason())?4:2;
    *occluded=hr==DXGI_STATUS_OCCLUDED; s->acquired=nullptr; s->present_pending=true; return 0;
}
extern "C" int zenit_d12_surface_discard(ZenitD12Surface *s,ZenitD12Texture *t) {
    if (!s || !t || s->acquired!=t) return 1;
    s->acquired=nullptr; return 0;
}
extern "C" int zenit_d12_surface_destroy(ZenitD12Surface *s,uint32_t timeout) {
    if (!s) return 1;
    int result=surface_idle(s,timeout); if (result) return result;
    surface_release_buffers(s); surface_release_composition(s); s->raw->Release(); free(s); return 0;
}
extern "C" int zenit_d12_surface_size(ZenitD12Surface *s,uint32_t *w,uint32_t *h) {
    if (!s || !w || !h) return 1;
    DXGI_SWAP_CHAIN_DESC1 desc={}; if (FAILED(s->raw->GetDesc1(&desc))) return 2;
    *w=desc.Width; *h=desc.Height; return 0;
}
