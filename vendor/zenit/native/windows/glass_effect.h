// Included by d2d_composite.cpp; uses its Owned COM holder and error reporter.
#include <d2d1effectauthor.h>
#include <d3dcompiler.h>
#include <string.h>
static const GUID glass_effect_id={0x8276b6c2,0x77c0,0x4ac1,{0xaf,0x39,0x89,0xd6,0x7a,0x1c,0x3a,0x85}};
static const GUID glass_shader_id={0x31cb019c,0x19b6,0x43fd,{0xa0,0xd3,0x7d,0xf1,0x18,0x25,0x83,0x46}};
struct GlassConstants {
    float extent[4],rect[4],radii[4],tint[4],specular[4],optic[4];
    float surface[4],bottom[4],lens[4],edge[4],positions[4],strengths[4];
    float local[2][4],forward[2][4];
};
static_assert(sizeof(GlassConstants)==256,"glass shader constant ABI");
#include "glass_shader.h"
static INIT_ONCE glass_compile_once=INIT_ONCE_STATIC_INIT;
static BYTE *glass_code=nullptr;static size_t glass_code_size=0;
static BOOL CALLBACK compile_glass(PINIT_ONCE,void *,void **) {
    // One process-wide immutable bytecode copy; DLL and temporary COM blobs
    // are released immediately. System32 lookup avoids current-dir DLL loads.
    HMODULE module=LoadLibraryExW(L"d3dcompiler_47.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
    if(!module)return TRUE;
    auto compile=(pD3DCompile)GetProcAddress(module,"D3DCompile");
    ID3DBlob *code=nullptr,*errors=nullptr;
    HRESULT hr=compile?compile(glass_shader,sizeof(glass_shader)-1,"zenit-glass",nullptr,nullptr,"main","ps_4_0",D3DCOMPILE_ENABLE_STRICTNESS|D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&errors):E_FAIL;
    if(FAILED(hr)){fprintf(stderr,"[windows-glass-compile] hr=0x%08lx %s\n",(unsigned long)hr,errors?(const char *)errors->GetBufferPointer():"");}
    else {size_t size=code->GetBufferSize();BYTE *copy=(BYTE *)malloc(size);if(copy){memcpy(copy,code->GetBufferPointer(),size);glass_code=copy;glass_code_size=size;}}
    if(errors)errors->Release();if(code)code->Release();FreeLibrary(module);return TRUE;
}
class GlassEffect final: public ID2D1EffectImpl, public ID2D1DrawTransform {
    LONG refs=1;Owned<ID2D1DrawInfo> draw;
public:
    GlassConstants constants={};
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id,void **out) override {
        if(!out)return E_POINTER;*out=nullptr;
        if(id==IID_IUnknown||id==__uuidof(ID2D1EffectImpl))*out=(ID2D1EffectImpl *)this;
        else if(id==__uuidof(ID2D1DrawTransform)||id==__uuidof(ID2D1Transform)||id==__uuidof(ID2D1TransformNode))*out=(ID2D1DrawTransform *)this;
        else return E_NOINTERFACE;AddRef();return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override{return InterlockedIncrement(&refs);}
    ULONG STDMETHODCALLTYPE Release() override{ULONG n=InterlockedDecrement(&refs);if(!n){this->~GlassEffect();free(this);}return n;}
    HRESULT STDMETHODCALLTYPE Initialize(ID2D1EffectContext *context,ID2D1TransformGraph *graph) override {
        InitOnceExecuteOnce(&glass_compile_once,compile_glass,nullptr,nullptr);
        if(!glass_code)return E_FAIL;
        HRESULT hr=S_OK;if(!context->IsShaderLoaded(glass_shader_id))hr=context->LoadPixelShader(glass_shader_id,glass_code,(UINT32)glass_code_size);
        return FAILED(hr)?hr:graph->SetSingleTransformNode(this);
    }
    HRESULT STDMETHODCALLTYPE PrepareForRender(D2D1_CHANGE_TYPE) override{return draw.p?draw.p->SetPixelShaderConstantBuffer((BYTE *)&constants,sizeof(constants)):E_FAIL;}
    HRESULT STDMETHODCALLTYPE SetGraph(ID2D1TransformGraph *) override{return E_NOTIMPL;}
    UINT32 STDMETHODCALLTYPE GetInputCount() const override{return 2;}
    HRESULT STDMETHODCALLTYPE SetDrawInfo(ID2D1DrawInfo *info) override {
        if(draw.p)draw.p->Release();draw.p=info;info->AddRef();
        D2D1_INPUT_DESCRIPTION input={D2D1_FILTER_MIN_MAG_MIP_LINEAR,0};
        HRESULT hr=info->SetInputDescription(0,input);if(FAILED(hr))return hr;
        hr=info->SetInputDescription(1,input);if(FAILED(hr))return hr;
        hr=info->SetOutputBuffer(D2D1_BUFFER_PRECISION_32BPC_FLOAT,D2D1_CHANNEL_DEPTH_4);if(FAILED(hr))return hr;
        return info->SetPixelShader(glass_shader_id,D2D1_PIXEL_OPTIONS_NONE);
    }
    D2D1_RECT_L extent() const {return {0,0,(LONG)ceilf(constants.extent[0]),(LONG)ceilf(constants.extent[1])};}
    HRESULT STDMETHODCALLTYPE MapOutputRectToInputRects(const D2D1_RECT_L *,D2D1_RECT_L *in,UINT32 count) const override {
        if(count!=2)return E_INVALIDARG;
        // Refraction/magnification can sample across the captured image. D2D
        // must make the entire bounded capture available to both inputs.
        in[0]=in[1]=extent();return S_OK;
    }
    HRESULT STDMETHODCALLTYPE MapInputRectsToOutputRect(const D2D1_RECT_L *,const D2D1_RECT_L *,UINT32 count,D2D1_RECT_L *out,D2D1_RECT_L *opaque) override {
        if(count!=2)return E_INVALIDARG;*out=extent();*opaque={0,0,0,0};return S_OK;
    }
    HRESULT STDMETHODCALLTYPE MapInvalidRect(UINT32 index,D2D1_RECT_L,D2D1_RECT_L *out) const override {
        if(index>=2)return E_INVALIDARG;*out=extent();return S_OK;
    }
    static HRESULT CALLBACK create(IUnknown **out){
        void *storage=malloc(sizeof(GlassEffect));if(!storage)return E_OUTOFMEMORY;
        *out=(ID2D1EffectImpl *)new(storage)GlassEffect;return S_OK;
    }
    static HRESULT CALLBACK set(IUnknown *effect,const BYTE *bytes,UINT32 size){
        if(!bytes||size!=sizeof(GlassConstants))return E_INVALIDARG;
        GlassConstants c;memcpy(&c,bytes,size);
        float v[sizeof(c)/sizeof(float)];memcpy(v,&c,sizeof(c));
        for(unsigned i=0;i<sizeof(c)/sizeof(float);++i)if(!isfinite(v[i]))return E_INVALIDARG;
        if(c.extent[0]<=0 || c.extent[1]<=0 || c.extent[0]>16384 || c.extent[1]>16384 ||
           c.rect[0]<=0 || c.rect[1]<=0 || c.rect[2]<=0)return E_INVALIDARG;
        auto self=static_cast<GlassEffect *>(static_cast<ID2D1EffectImpl *>(effect));self->constants=c;return S_OK;
    }
    static HRESULT CALLBACK get(const IUnknown *effect,BYTE *bytes,UINT32 size,UINT32 *actual){
        if(actual)*actual=sizeof(GlassConstants);if(!bytes)return S_OK;if(size<sizeof(GlassConstants))return E_INVALIDARG;
        auto self=static_cast<const GlassEffect *>(static_cast<const ID2D1EffectImpl *>(effect));memcpy(bytes,&self->constants,sizeof(GlassConstants));return S_OK;
    }
};
static int glass_effect(ID2D1DeviceContext *dc,ID2D1Image *blur,ID2D1Image *sharp,const GlassConstants &c,ID2D1Effect **out) {
    Owned<ID2D1Factory> base;Owned<ID2D1Factory1> factory;dc->GetFactory(&base.p);
    if(failed(base.p->QueryInterface(__uuidof(ID2D1Factory1),(void **)&factory.p),"glass-factory"))return 0;
    Owned<ID2D1Properties> properties;
    if(FAILED(factory.p->GetEffectProperties(glass_effect_id,&properties.p))) {
        const wchar_t xml[]=L"<?xml version='1.0'?><Effect><Property name='DisplayName' type='string' value='Zenit Glass'/><Property name='Author' type='string' value='Zenit'/><Property name='Category' type='string' value='Backdrop'/><Property name='Description' type='string' value='Double-interface optical glass'/><Inputs><Input name='Blur'/><Input name='Sharp'/></Inputs><Property name='Constants' type='blob'><Property name='DisplayName' type='string' value='Constants'/></Property></Effect>";
        D2D1_PROPERTY_BINDING binding={L"Constants",GlassEffect::set,GlassEffect::get};
        if(failed(factory.p->RegisterEffectFromString(glass_effect_id,xml,&binding,1,GlassEffect::create),"glass-register"))return 0;
    }
    if(failed(dc->CreateEffect(glass_effect_id,out),"glass-effect"))return 0;
    (*out)->SetInput(0,blur);(*out)->SetInput(1,sharp);
    return !failed((*out)->SetValue(0,D2D1_PROPERTY_TYPE_BLOB,(BYTE *)&c,sizeof(c)),"glass-constants");
}
