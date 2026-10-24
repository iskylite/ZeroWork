// Included by d2d_composite.cpp; uses its Owned COM holder and error reporter.
#include <d2d1effectauthor.h>
#include <d3dcompiler.h>
#include <string.h>
static const GUID conic_effect_id={0x414fec30,0x77c0,0x4ac1,{0xaf,0x39,0x89,0xd6,0x7a,0x1c,0x3a,0x85}};
static const GUID conic_shader_id={0x68452782,0x19b6,0x43fd,{0xa0,0xd3,0x7d,0xf1,0x18,0x25,0x83,0x46}};
struct ConicConstants {
    float extent[4]; // physical output width/height, normalized center
    float info[4];   // stop count, start angle, extend mode, phase
    float colors[16][4]; // linear premultiplied RGBA
    float positions[16][4]; // HLSL array register alignment
    float noise[4]; // mode, logical scale, intensity, effective seed
    float canvas[4]; // physical image origin, unused
    float local[2][4]; // physical image coordinates -> centered logical rect
};
static_assert(sizeof(ConicConstants)==608,"procedural shader constant ABI");
static INIT_ONCE conic_compile_once=INIT_ONCE_STATIC_INIT;
static BYTE *conic_code=nullptr;static size_t conic_code_size=0;
static BOOL CALLBACK compile_conic(PINIT_ONCE,void *,void **) {
    // One process-wide immutable bytecode copy; DLL and temporary COM blobs
    // are released immediately. System32 lookup avoids current-dir DLL loads.
    HMODULE module=LoadLibraryExW(L"d3dcompiler_47.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
    if(!module)return TRUE;
    auto compile=(pD3DCompile)GetProcAddress(module,"D3DCompile");
    const char shader[]=R"hlsl(
cbuffer Params : register(b0) { float4 extent;float4 info;float4 colors[16];float4 positions[16];float4 noise;float4 canvas;float4 local[2]; };
uint wang(uint x){x=(x^61u)^(x>>16u);x+=x<<3u;x^=x>>4u;x*=0x27d4eb2du;x^=x>>15u;return x;}
float hash2d(float2 p){uint ix=(uint)(abs(p.x)*1000.0),iy=(uint)(abs(p.y)*1000.0);return (float)wang(ix^wang(iy*2654435761u))/4294967295.0;}
float value_noise(float2 p,float scale,uint seed){
 float2 sp=p/max(scale,.001)+float2((float)seed*17.3,(float)seed*31.7);
 float2 i=floor(sp),f=frac(sp),u=f*f*(3-2*f);
 return lerp(lerp(hash2d(i),hash2d(i+float2(1,0)),u.x),lerp(hash2d(i+float2(0,1)),hash2d(i+1),u.x),u.y);
}
float3 encode(float3 x) { return float3(x.r<=.0031308?12.92*x.r:1.055*pow(x.r,1.0/2.4)-.055,
 x.g<=.0031308?12.92*x.g:1.055*pow(x.g,1.0/2.4)-.055,x.b<=.0031308?12.92*x.b:1.055*pow(x.b,1.0/2.4)-.055); }
float4 main(float4 pixel:SV_POSITION,float4 scene:SCENE_POSITION):SV_Target {
 if(noise.x>0&&noise.y>0){
  float n;uint seed=(uint)noise.w;
  if(noise.x==1){float2 p=float2(dot(scene.xy,local[0].xy)+local[0].z,dot(scene.xy,local[1].xy)+local[1].z);n=value_noise(p,noise.y,seed)-.5;}
  else n=hash2d(floor(scene.xy+canvas.xy)+float2((float)(seed&255u)*3.7,(float)((seed>>8u)&255u)*5.1))-.5;
  float4 c=colors[0];float3 rgb=c.a>0?c.rgb/c.a:0;rgb=saturate(rgb+n*noise.z);
  return float4(saturate(encode(rgb))*c.a,c.a);
 }
 float2 uv=scene.xy/extent.xy-extent.zw;
 float t=frac((atan2(uv.y,uv.x)-info.y)/6.283185307179586+info.w);
 if(info.z==1)t=frac(t);else if(info.z==2){float q=fmod(abs(t),2);t=q>1?2-q:q;}else t=saturate(t);
 uint n=(uint)info.x;float4 c=colors[0];
 if(t>=positions[n-1].x)c=colors[n-1];
 else if(t>positions[0].x){
  for(uint i=1;i<n;i++){if(t<=positions[i].x){float d=positions[i].x-positions[i-1].x;
   c=lerp(colors[i-1],colors[i],d>0?saturate((t-positions[i-1].x)/d):1);break;}}
 }
 float3 rgb=c.a>0?encode(max(c.rgb/c.a,0)):0;
 return float4(saturate(rgb)*c.a,c.a);
}
)hlsl";
    ID3DBlob *code=nullptr,*errors=nullptr;
    HRESULT hr=compile?compile(shader,sizeof(shader)-1,"zenit-conic",nullptr,nullptr,"main","ps_4_0",D3DCOMPILE_ENABLE_STRICTNESS|D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&errors):E_FAIL;
    if(FAILED(hr)){fprintf(stderr,"[windows-conic-compile] hr=0x%08lx %s\n",(unsigned long)hr,errors?(const char *)errors->GetBufferPointer():"");}
    else {size_t size=code->GetBufferSize();BYTE *copy=(BYTE *)malloc(size);if(copy){memcpy(copy,code->GetBufferPointer(),size);conic_code=copy;conic_code_size=size;}}
    if(errors)errors->Release();if(code)code->Release();FreeLibrary(module);return TRUE;
}
class ConicEffect final: public ID2D1EffectImpl, public ID2D1DrawTransform {
    LONG refs=1;Owned<ID2D1DrawInfo> draw;
public:
    ConicConstants constants={};
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id,void **out) override {
        if(!out)return E_POINTER;*out=nullptr;
        if(id==IID_IUnknown||id==__uuidof(ID2D1EffectImpl))*out=(ID2D1EffectImpl *)this;
        else if(id==__uuidof(ID2D1DrawTransform)||id==__uuidof(ID2D1Transform)||id==__uuidof(ID2D1TransformNode))*out=(ID2D1DrawTransform *)this;
        else return E_NOINTERFACE;AddRef();return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override{return InterlockedIncrement(&refs);}
    ULONG STDMETHODCALLTYPE Release() override{ULONG n=InterlockedDecrement(&refs);if(!n){this->~ConicEffect();free(this);}return n;}
    HRESULT STDMETHODCALLTYPE Initialize(ID2D1EffectContext *context,ID2D1TransformGraph *graph) override {
        InitOnceExecuteOnce(&conic_compile_once,compile_conic,nullptr,nullptr);
        if(!conic_code)return E_FAIL;
        HRESULT hr=S_OK;if(!context->IsShaderLoaded(conic_shader_id))hr=context->LoadPixelShader(conic_shader_id,conic_code,(UINT32)conic_code_size);
        return FAILED(hr)?hr:graph->SetSingleTransformNode(this);
    }
    HRESULT STDMETHODCALLTYPE PrepareForRender(D2D1_CHANGE_TYPE) override{return draw.p?draw.p->SetPixelShaderConstantBuffer((BYTE *)&constants,sizeof(constants)):E_FAIL;}
    HRESULT STDMETHODCALLTYPE SetGraph(ID2D1TransformGraph *) override{return E_NOTIMPL;}
    UINT32 STDMETHODCALLTYPE GetInputCount() const override{return 0;}
    HRESULT STDMETHODCALLTYPE SetDrawInfo(ID2D1DrawInfo *info) override {
        if(draw.p)draw.p->Release();draw.p=info;info->AddRef();
        return info->SetPixelShader(conic_shader_id,D2D1_PIXEL_OPTIONS_NONE);
    }
    HRESULT STDMETHODCALLTYPE MapOutputRectToInputRects(const D2D1_RECT_L *,D2D1_RECT_L *,UINT32 count) const override{return count?E_INVALIDARG:S_OK;}
    HRESULT STDMETHODCALLTYPE MapInputRectsToOutputRect(const D2D1_RECT_L *,const D2D1_RECT_L *,UINT32 count,D2D1_RECT_L *out,D2D1_RECT_L *opaque) override {
        if(count)return E_INVALIDARG;*out={0,0,(LONG)ceilf(constants.extent[0]),(LONG)ceilf(constants.extent[1])};*opaque={0,0,0,0};return S_OK;
    }
    HRESULT STDMETHODCALLTYPE MapInvalidRect(UINT32,D2D1_RECT_L,D2D1_RECT_L *) const override{return E_INVALIDARG;}
    static HRESULT CALLBACK create(IUnknown **out){
        void *storage=malloc(sizeof(ConicEffect));if(!storage)return E_OUTOFMEMORY;
        *out=(ID2D1EffectImpl *)new(storage)ConicEffect;return S_OK;
    }
    static HRESULT CALLBACK set(IUnknown *effect,const BYTE *bytes,UINT32 size){
        if(!bytes||size!=sizeof(ConicConstants))return E_INVALIDARG;
        ConicConstants c;memcpy(&c,bytes,size);
        for(unsigned i=0;i<4;i++)if(!isfinite(c.extent[i])||!isfinite(c.info[i]))return E_INVALIDARG;
        for(unsigned i=0;i<4;i++)if(!isfinite(c.noise[i])||!isfinite(c.canvas[i])||!isfinite(c.local[0][i])||!isfinite(c.local[1][i]))return E_INVALIDARG;
        if(c.noise[0]<0||c.noise[0]>2||floorf(c.noise[0])!=c.noise[0]||c.noise[3]<0||c.noise[3]>255)return E_INVALIDARG;
        if(c.extent[0]<=0||c.extent[1]<=0||c.extent[0]>2147483000.f||c.extent[1]>2147483000.f||c.info[0]<1||c.info[0]>16||floorf(c.info[0])!=c.info[0])return E_INVALIDARG;
        for(unsigned i=0;i<(unsigned)c.info[0];i++){
            if(!isfinite(c.positions[i][0])||c.positions[i][0]<0||c.positions[i][0]>1||(i&&c.positions[i][0]<c.positions[i-1][0]))return E_INVALIDARG;
            for(unsigned j=0;j<4;j++)if(!isfinite(c.colors[i][j])||c.colors[i][j]<0||c.colors[i][j]>1)return E_INVALIDARG;
        }
        auto self=static_cast<ConicEffect *>(static_cast<ID2D1EffectImpl *>(effect));self->constants=c;return S_OK;
    }
    static HRESULT CALLBACK get(const IUnknown *effect,BYTE *bytes,UINT32 size,UINT32 *actual){
        if(actual)*actual=sizeof(ConicConstants);if(!bytes)return S_OK;if(size<sizeof(ConicConstants))return E_INVALIDARG;
        auto self=static_cast<const ConicEffect *>(static_cast<const ID2D1EffectImpl *>(effect));memcpy(bytes,&self->constants,sizeof(ConicConstants));return S_OK;
    }
};
static int procedural_brush(ID2D1DeviceContext *dc,const D2D1_RECT_F *rect,const ConicConstants &c,const D2D1_MATRIX_3X2_F &transform,ID2D1Brush **out) {
    Owned<ID2D1Factory> base;Owned<ID2D1Factory1> factory;dc->GetFactory(&base.p);
    if(failed(base.p->QueryInterface(__uuidof(ID2D1Factory1),(void **)&factory.p),"conic-factory"))return 0;
    // Register only once per factory, including after renderer/device rebuild.
    Owned<ID2D1Properties> properties;
    if(FAILED(factory.p->GetEffectProperties(conic_effect_id,&properties.p))) {
        const wchar_t xml[]=L"<?xml version='1.0'?><Effect><Property name='DisplayName' type='string' value='Zenit Conic'/><Property name='Author' type='string' value='Zenit'/><Property name='Category' type='string' value='Gradient'/><Property name='Description' type='string' value='Linear premultiplied conic gradient'/><Inputs/><Property name='Constants' type='blob'><Property name='DisplayName' type='string' value='Constants'/></Property></Effect>";
        D2D1_PROPERTY_BINDING binding={L"Constants",ConicEffect::set,ConicEffect::get};
        if(failed(factory.p->RegisterEffectFromString(conic_effect_id,xml,&binding,1,ConicEffect::create),"conic-register"))return 0;
    }
    Owned<ID2D1Effect> effect;if(failed(dc->CreateEffect(conic_effect_id,&effect.p),"conic-effect"))return 0;
    float w=rect->right-rect->left,h=rect->bottom-rect->top;
    if(failed(effect.p->SetValue(0,D2D1_PROPERTY_TYPE_BLOB,(BYTE *)&c,sizeof(c)),"conic-constants"))return 0;
    Owned<ID2D1Image> image;effect.p->GetOutput(&image.p);
    D2D1_IMAGE_BRUSH_PROPERTIES ip={{0,0,w,h},D2D1_EXTEND_MODE_CLAMP,D2D1_EXTEND_MODE_CLAMP,D2D1_INTERPOLATION_MODE_LINEAR};
    D2D1_BRUSH_PROPERTIES bp={1,transform};ID2D1ImageBrush *brush=nullptr;
    if(failed(dc->CreateImageBrush(image.p,&ip,&bp,&brush),"conic-brush"))return 0;*out=brush;return 1;
}
static int conic_brush(ID2D1DeviceContext *dc,const D2D1_RECT_F *rect,const ZenitGradient *gradient,const D2D1_GRADIENT_STOP *stops,ID2D1Brush **out) {
    if(!isfinite(gradient->start_angle)||!isfinite(gradient->conic_phase)||!isfinite(gradient->center[0])||!isfinite(gradient->center[1]))return 0;
    ConicConstants c={};float dx=96,dy=96;dc->GetDpi(&dx,&dy);
    c.extent[0]=(rect->right-rect->left)*dx/96;c.extent[1]=(rect->bottom-rect->top)*dy/96;
    c.extent[2]=gradient->center[0];c.extent[3]=gradient->center[1];
    c.info[0]=(float)gradient->count;c.info[1]=gradient->start_angle;c.info[2]=(float)gradient->extend;c.info[3]=gradient->conic_phase;
    for(unsigned i=0;i<gradient->count;i++){c.positions[i][0]=stops[i].position;const auto &color=stops[i].color;c.colors[i][0]=color.r*color.a;c.colors[i][1]=color.g*color.a;c.colors[i][2]=color.b*color.a;c.colors[i][3]=color.a;}
    return procedural_brush(dc,rect,c,{1,0,0,1,rect->left,rect->top},out);
}
extern "C" int zenit_d2d_noise_brush(ID2D1RenderTarget *target,const D2D1_RECT_F *rect,const ZenitNoise *noise,const D2D1_COLOR_F *color,uint32_t frame,float offset_x,float offset_y,ID2D1Brush **out) {
    *out=nullptr;auto dc=static_cast<ID2D1DeviceContext *>(target);
    if(noise->mode>2||noise->seed>255||!isfinite(noise->scale)||!isfinite(noise->intensity))return 0;
    D2D1_MATRIX_3X2_F matrix,inv;dc->GetTransform(&matrix);inv=matrix;
    if(!D2D1InvertMatrix(&inv)){ID2D1SolidColorBrush *brush=nullptr;if(FAILED(dc->CreateSolidColorBrush(*color,&brush)))return 0;*out=brush;return 1;}
    float dx=96,dy=96;dc->GetDpi(&dx,&dy);dx/=96;dy/=96;
    float left=INFINITY,top=INFINITY,right=-INFINITY,bottom=-INFINITY;
    for(unsigned i=0;i<4;i++){float x=i&1?rect->right:rect->left,y=i&2?rect->bottom:rect->top;
        float tx=x*matrix._11+y*matrix._21+matrix._31,ty=x*matrix._12+y*matrix._22+matrix._32;
        left=fminf(left,tx);top=fminf(top,ty);right=fmaxf(right,tx);bottom=fmaxf(bottom,ty);}
    left=floorf(left*dx)/dx;top=floorf(top*dy)/dy;right=ceilf(right*dx)/dx;bottom=ceilf(bottom*dy)/dy;
    ConicConstants c={};c.extent[0]=(right-left)*dx;c.extent[1]=(bottom-top)*dy;c.info[0]=1;
    const float channels[]={color->r,color->g,color->b};
    for(unsigned i=0;i<3;i++){float v=channels[i];if(!isfinite(v)||v<0||v>1)return 0;c.colors[0][i]=(v<=.04045f?v/12.92f:powf((v+.055f)/1.055f,2.4f))*color->a;}c.colors[0][3]=color->a;
    c.noise[0]=(float)noise->mode;c.noise[1]=noise->scale;c.noise[2]=noise->intensity;c.noise[3]=(float)(noise->mode==2?noise->seed^(frame&255u):noise->seed);
    c.canvas[0]=(left+offset_x)*dx;c.canvas[1]=(top+offset_y)*dy;
    c.local[0][0]=inv._11/dx;c.local[0][1]=inv._21/dy;c.local[0][2]=left*inv._11+top*inv._21+inv._31-(rect->left+rect->right)/2;
    c.local[1][0]=inv._12/dx;c.local[1][1]=inv._22/dy;c.local[1][2]=left*inv._12+top*inv._22+inv._32-(rect->top+rect->bottom)/2;
    // Cancel the geometry transform for the brush: rasterize in physical
    // target pixels, then map those pixels back to the primitive's space.
    D2D1_MATRIX_3X2_F brush=inv;brush._31=left*inv._11+top*inv._21+inv._31;brush._32=left*inv._12+top*inv._22+inv._32;
    D2D1_RECT_F bounds={left,top,right,bottom};return procedural_brush(dc,&bounds,c,brush,out);
}
