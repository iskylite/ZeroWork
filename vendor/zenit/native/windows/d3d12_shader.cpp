#include "d3d12_resources.h"
#include <windows.h>
#include <d3dcompiler.h>
#include <d3d12shader.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "d3d12_warp_shader.h"
#include "dxbc_cache.h"
struct ZenitD12Shader { ID3DBlob *code; LONG refs; char entry[96]; };
extern "C" const char *zenit_d12_shader_entry(ZenitD12Shader *shader) { return shader->entry; }
#ifdef ZENIT_D12_TEST
static LONG live_shaders;
extern "C" long zenit_d12_test_live_shaders() { return InterlockedCompareExchange(&live_shaders, 0, 0); }
#endif
static const UINT kCompileFlags = D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3;
// Bumping the tag drops every old D3D12 entry (shader model 5.1 bytecode).
static const char *const kCacheTag = "dxbc-v2|5_1";
extern "C" int zenit_d12_shader_compile(const void *source, size_t source_size, const char *entry,
    uint32_t stage, ZenitD12Shader **out, char **diagnostic, size_t *diagnostic_size) {
    if (!out || !diagnostic || !diagnostic_size) return 1;
    *out = nullptr; *diagnostic = nullptr; *diagnostic_size = 0;
    if (!source || !source_size || !entry || !*entry || stage < 1 || stage > 3) return 1;
    const char *profile = stage == 1 ? "vs_5_1" : stage == 2 ? "ps_5_1" : "cs_5_1";
    ID3DBlob *code = nullptr, *messages = nullptr;
    HRESULT hr = dxbc_compile_cached(kCacheTag, source, source_size, entry, entry, profile, kCompileFlags, &code, &messages);
    if (messages) {
        size_t size = messages->GetBufferSize();
        const char *text = (const char *)messages->GetBufferPointer();
        if (size && text[size - 1] == 0) --size;
        if (size) {
            *diagnostic = (char *)malloc(size);
            if (!*diagnostic) { messages->Release(); if (code) code->Release(); return 2; }
            memcpy(*diagnostic, text, size); *diagnostic_size = size;
        }
        messages->Release();
    }
    if (FAILED(hr)) { if (code) code->Release(); return 3; }
    if (!code) return 2;
    auto shader = (ZenitD12Shader *)calloc(1, sizeof(ZenitD12Shader));
    if (!shader) { code->Release(); return 2; }
#ifdef ZENIT_D12_TEST
    InterlockedIncrement(&live_shaders);
#endif
    strncpy(shader->entry, entry, sizeof(shader->entry)-1);
    shader->code = code; shader->refs = 1; *out = shader; return 0;
}
extern "C" void zenit_d12_shader_retain(ZenitD12Shader *shader) { InterlockedIncrement(&shader->refs); }
extern "C" void zenit_d12_shader_release(ZenitD12Shader *shader) {
    if (!shader || InterlockedDecrement(&shader->refs) != 0) return;
    shader->code->Release(); free(shader);
#ifdef ZENIT_D12_TEST
    InterlockedDecrement(&live_shaders);
#endif
}
extern "C" const void *zenit_d12_shader_data(ZenitD12Shader *shader) { return shader->code->GetBufferPointer(); }
extern "C" size_t zenit_d12_shader_size(ZenitD12Shader *shader) { return shader->code->GetBufferSize(); }
extern "C" void zenit_d12_shader_diagnostic_free(char *diagnostic) { free(diagnostic); }

extern "C" int zenit_d12_shader_bindings(ZenitD12Shader *shader, ZenitD12ShaderBinding *out,
    uint32_t capacity, uint32_t *count) {
    if (!shader || !count || (capacity && !out)) return 1;
    *count=0;
    ID3D12ShaderReflection *reflection=nullptr;
    if (FAILED(D3DReflect(shader->code->GetBufferPointer(),shader->code->GetBufferSize(),IID_ID3D12ShaderReflection,(void **)&reflection))) return 2;
    D3D12_SHADER_DESC desc={};
    if (FAILED(reflection->GetDesc(&desc))) { reflection->Release(); return 2; }
    *count=desc.BoundResources;
    if (!capacity) { reflection->Release(); return 0; }
    if (capacity<desc.BoundResources) { reflection->Release(); return 1; }
    int status=0;
    for (uint32_t i=0;i<desc.BoundResources;++i) {
        D3D12_SHADER_INPUT_BIND_DESC resource={};
        if (FAILED(reflection->GetResourceBindingDesc(i,&resource))) { status=2; break; }
        if (!resource.BindCount || resource.BindCount==UINT32_MAX) { status=3; break; }
        auto &b=out[i]; b={}; b.group=resource.Space; b.binding=resource.BindPoint; b.count=resource.BindCount;
        switch (resource.Type) {
        case D3D_SIT_CBUFFER: {
            b.kind=0; D3D12_SHADER_BUFFER_DESC buffer={};
            if (FAILED(reflection->GetConstantBufferByName(resource.Name)->GetDesc(&buffer))) { status=2; }
            b.min_size=buffer.Size; break;
        }
        case D3D_SIT_TEXTURE:
            b.kind=1;
            switch (resource.Dimension) {
            case D3D_SRV_DIMENSION_TEXTURE1D: b.dimension=1; break;
            case D3D_SRV_DIMENSION_TEXTURE2D: b.dimension=2; break;
            case D3D_SRV_DIMENSION_TEXTURE2DARRAY: b.dimension=3; break;
            case D3D_SRV_DIMENSION_TEXTURECUBE: b.dimension=4; break;
            case D3D_SRV_DIMENSION_TEXTURECUBEARRAY: b.dimension=5; break;
            case D3D_SRV_DIMENSION_TEXTURE3D: b.dimension=6; break;
            default: status=3; break;
            }
            switch (resource.ReturnType) {
            case D3D_RETURN_TYPE_FLOAT: case D3D_RETURN_TYPE_UNORM: case D3D_RETURN_TYPE_SNORM: b.sample_type=1; break;
            case D3D_RETURN_TYPE_SINT: b.sample_type=4; break;
            case D3D_RETURN_TYPE_UINT: b.sample_type=5; break;
            default: status=3; break;
            }
            break;
        case D3D_SIT_STRUCTURED:
            b.kind=2; b.stride=resource.NumSamples;
            if (!b.stride || b.stride>2048 || b.stride%4) status=3;
            break;
        case D3D_SIT_BYTEADDRESS: b.kind=2; break;
        case D3D_SIT_SAMPLER:
            b.kind=4; b.sampler_type=(resource.uFlags & D3D_SIF_COMPARISON_SAMPLER)?3:1; break;
        default: status=3; break;
        }
        if (status) break;
    }
    reflection->Release(); return status;
}

// Inspect compiler bytecode, not HLSL spelling: only buffer array atomics with
// a relative descriptor index carrying the SM5.1 nonuniform qualifier require
// this capability. Reuse the token parser used by the WARP lowering path.
extern "C" int zenit_d12_shader_non_uniform_buffer_atomics(ZenitD12Shader *shader) {
    if (!shader) return -1;
    size_t size=shader->code->GetBufferSize();
    const auto *data=(const uint32_t *)shader->code->GetBufferPointer();
    if (size<32 || size%4 || data[0]!=0x43425844 || data[6]!=size || data[7]>(size-32)/4) return -1;
    for (uint32_t part=0;part<data[7];++part) {
        size_t offset=data[8+part];
        if (offset%4 || offset<(8+data[7])*4 || offset>size-8) return -1;
        const auto *chunk=data+offset/4;
        if (chunk[1]>size-offset-8) return -1;
        if (chunk[0]!=0x58454853) continue; // SHEX
        if (chunk[1]%4) return -1;
        zenit_warp::Words code(chunk+2,chunk+2+chunk[1]/4);
        if (code.size()<2 || code[1]!=code.size() || (code[0]&255)!=0x51) return -1;
        std::vector<uint32_t> arrays;
        for (size_t at=2,end,payload;at<code.size();at=end) {
            if (!zenit_warp::instruction(code,at,end,payload)) return -1;
            uint32_t op=code[at]&2047;
            if (op!=157 && op!=158) continue; // raw/structured UAV declaration
            zenit_warp::Operand resource;
            if (!zenit_warp::operand(code,payload,end,resource) || resource.dimensions!=3 ||
                resource.immediate[0]==SIZE_MAX || resource.immediate[1]==SIZE_MAX || resource.immediate[2]==SIZE_MAX) return -1;
            if (code[resource.immediate[1]]<code[resource.immediate[2]]) arrays.push_back(code[resource.immediate[0]]);
        }
        if (arrays.empty()) return 0;
        for (size_t at=2,end,payload;at<code.size();at=end) {
            if (!zenit_warp::instruction(code,at,end,payload)) return -1;
            uint32_t op=code[at]&2047;
            if (op<169 || op>189) continue;
            while (payload<end) {
                size_t begin=payload; zenit_warp::Operand resource;
                if (!zenit_warp::operand(code,payload,end,resource)) return -1;
                if (resource.type!=30 || resource.dimensions!=2 || resource.immediate[0]==SIZE_MAX || resource.immediate[1]!=SIZE_MAX) continue;
                bool array=false;
                for (uint32_t id:arrays) if (id==code[resource.immediate[0]]) array=true;
                if (!array) continue;
                bool nonuniform=false;
                while (code[begin]&0x80000000u) nonuniform|=bool(code[++begin]&(1u<<17));
                if (nonuniform) return 1;
            }
        }
        return 0;
    }
    return -1;
}

extern "C" int zenit_d12_shader_warp_blob(ZenitD12Shader *shader, void **out) {
    if (!shader || !out) return 1;
    HRESULT hr=zenit_warp::blob(shader->code, (ID3DBlob **)out);
    if (FAILED(hr)) fprintf(stderr,"WARP shader lowering failed: 0x%08lx\n",(unsigned long)hr);

    return FAILED(hr) ? 2 : 0;
}

#ifdef ZENIT_D12_TEST
extern "C" int zenit_d12_test_warp_shader_parser() {
    // Literal payloads that look like resource tokens must remain opaque.
    zenit_warp::Words literal={0x00004002,0x00207000,0,5,0};
    size_t at=0; zenit_warp::Operand result;
    if (!zenit_warp::operand(literal,at,literal.size(),result) || at!=5 || result.type!=4) return 1;
    // Relative descriptor indices must not become static aliases.
    zenit_warp::Words relative={0x06207000,0,4,0x00100001,0};
    at=0;
    if (!zenit_warp::operand(relative,at,relative.size(),result) || at!=5 || result.immediate[1]!=SIZE_MAX) return 2;
    for (size_t length=0;length<relative.size();++length) {
        at=0;
        if (zenit_warp::operand(relative,at,length,result)) return 3;
    }
    zenit_warp::Words invalid_custom={53,1};
    size_t end,payload;
    if (zenit_warp::instruction(invalid_custom,0,end,payload)) return 4;
    ID3DBlob *invalid=nullptr,*rewritten=nullptr;
    if (FAILED(D3DCreateBlob(32,&invalid))) return 5;
    memset(invalid->GetBufferPointer(),0,32);
    auto words=(uint32_t *)invalid->GetBufferPointer();
    words[0]=0x43425844; words[6]=32; words[7]=UINT32_MAX;
    HRESULT hr=zenit_warp::blob(invalid,&rewritten);
    invalid->Release();
    if (rewritten) rewritten->Release();
    return FAILED(hr) && !rewritten ? 0 : 6;
}
#endif

// Keep the portable compiler/cache blob immutable: the device-specific version
// is owned only for PSO creation and uses the original reflection and layout.
extern "C" int zenit_d12_shader_atomic_switch(ZenitD12Shader *shader, ZenitD12Shader **out) {
    if (!shader || !out) return 1;
    *out=nullptr;
    ID3DBlob *code=nullptr;
    if (FAILED(zenit_warp::blob(shader->code,&code,true))) return 3;
    if (!code) return 3;
    auto lowered=(ZenitD12Shader *)calloc(1,sizeof(ZenitD12Shader));
    if (!lowered) { code->Release(); return 2; }
    memcpy(lowered->entry,shader->entry,sizeof(lowered->entry));
    lowered->code=code; lowered->refs=1;
#ifdef ZENIT_D12_TEST
    InterlockedIncrement(&live_shaders);
#endif
    if (zenit_d12_shader_non_uniform_buffer_atomics(lowered)!=0) {
        zenit_d12_shader_release(lowered); return 3;
    }
    *out=lowered; return 0;
}
