#pragma once
#include <vector>
#include "dxbc_hash.h"

// SM5.1 token encodings are defined in Microsoft's
// DirectXShaderCompiler/include/dxc/Support/d3d12TokenizedProgramFormat.hpp.
// Older WARP versions ignore constant descriptor indices on buffer arrays.
// Keep dynamic loads/stores on the original array, but give constant accesses
// scalar declarations in an alias space mapped to the same descriptor table.
// Divergent atomics use scalar cases to avoid repeated updates on older WARP.
// Related upstream workaround: Mesa src/gallium/drivers/d3d12/d3d12_root_signature.cpp.
namespace zenit_warp {
using Words = std::vector<uint32_t>;
struct Declaration { uint32_t type, id, low, high, space; Words words; };
struct Alias { size_t declaration; uint32_t index, id; };
struct Operand { uint32_t type, dimensions, representation[3]; size_t immediate[3], begin[3], end[3]; };
struct Replacement { size_t at; Words words; };

static bool operand(const Words &code, size_t &at, size_t end, Operand &out, unsigned depth=0) {
    if (at>=end || depth>8) return false;
    uint32_t token=code[at++], extended=token;
    out={}; out.type=(token>>12)&255; out.dimensions=(token>>20)&3;
    for (auto &index:out.immediate) index=SIZE_MAX;
    while (extended&0x80000000u) {
        if (at>=end) return false;
        extended=code[at++];
    }
    for (uint32_t dimension=0;dimension<out.dimensions;++dimension) {
        uint32_t representation=(token>>(22+3*dimension))&7;
        out.representation[dimension]=representation; out.begin[dimension]=at;
        if (representation>4) return false;
        if (representation==0 || representation==3) {
            if (at>=end) return false;
            if (representation==0) out.immediate[dimension]=at;
            ++at;
        } else if (representation==1 || representation==4) {
            if (end-at<2) return false;
            at+=2;
        }
        if (representation>=2) {
            Operand relative;
            if (!operand(code,at,end,relative,depth+1)) return false;
        }
        out.end[dimension]=at;
    }
    if (out.type==4 || out.type==5) {
        uint32_t components=token&3;
        if (components!=1 && components!=2) return false;
        size_t count=(components==1?1:4)*(out.type==5?2:1);
        if (end-at<count) return false;
        at+=count;
    }
    return true;
}

static bool instruction(const Words &code, size_t at, size_t &end, size_t &payload) {
    if (at>=code.size()) return false;
    uint32_t token=code[at], length=(token>>24)&127;
    if ((token&2047)==53) {
        if (code.size()-at<2) return false;
        length=code[at+1];
        if (length<2) return false;
    }
    if (!length || length>code.size()-at) return false;
    end=at+length; payload=at+1;
    if ((token&2047)!=53) while (token&0x80000000u) {
        if (payload>=end) return false;
        token=code[payload++];
    }
    return true;
}

// Intel mode keeps declarations and static/SRV accesses in their original
// spaces. Only dynamic buffer atomics get per-lane constant-index cases.
static bool rewrite(Words &code, bool &changed, bool atomics_only=false) {
    changed=false;
    if (code.size()<2 || code[1]!=code.size() || (code[0]&255)!=0x51) return false;
    std::vector<Declaration> declarations;
    std::vector<Alias> aliases;
    std::vector<Replacement> replacements;
    uint32_t next_srv=0,next_uav=0;
    uint32_t temporary=0;
    bool has_temporaries=false;
    // Gather every resource ID before allocating aliases, including typed views.
    for (size_t at=2,end,payload;at<code.size();at=end) {
        if (!instruction(code,at,end,payload)) return false;
        uint32_t op=code[at]&2047;
        if (op==104) {
            if (end-payload!=1) return false;
            temporary=code[payload]; has_temporaries=true;
        }
        bool buffer=op==157 || op==158 || op==161 || op==162;
        if (!buffer && op!=88 && op!=156) continue;
        size_t cursor=payload; Operand resource;
        if (!operand(code,cursor,end,resource) || resource.dimensions!=3 ||
            resource.immediate[0]==SIZE_MAX || resource.immediate[1]==SIZE_MAX || resource.immediate[2]==SIZE_MAX) return false;
        uint32_t id=code[resource.immediate[0]];
        if (id==UINT32_MAX) return false;
        uint32_t &next=resource.type==7?next_srv:next_uav;
        if (next<=id) next=id+1;
        if (!buffer || (atomics_only && resource.type!=30)) continue;
        uint32_t low=code[resource.immediate[1]],high=code[resource.immediate[2]];
        if (low>=high) continue;
        // Raw declarations have only the space after the operand; structured
        // declarations also have the stride. Preserve all declaration flags.
        if (end-cursor!=size_t((op==158 || op==162)?2:1) || code[end-1]>=4) return false;
        declarations.push_back({resource.type,id,low,high,code[end-1],Words(code.begin()+at,code.begin()+end)});
    }
    if (declarations.empty()) return true;
    for (size_t at=2,end,payload;at<code.size();at=end) {
        if (!instruction(code,at,end,payload)) return false;
        uint32_t op=code[at]&2047;
        // Buffer reads, writes, atomics and dimension queries. Other instruction
        // payloads (notably custom data) must never be scanned as operands.
        if (!(op==61 || op==121 || (op>=165 && op<=189) || op==226 || op==227)) continue;
        if (atomics_only && (op<169 || op>189)) continue;
        while (payload<end) {
            size_t operand_at=payload;
            Operand resource;
            if (!operand(code,payload,end,resource)) return false;
            if ((resource.type!=7 && resource.type!=30) || resource.dimensions!=2 ||
                resource.immediate[0]==SIZE_MAX) continue;
            uint32_t id=code[resource.immediate[0]];
            for (size_t d=0;d<declarations.size();++d) {
                const auto &decl=declarations[d];
                if (decl.type!=resource.type || decl.id!=id) continue;
                if (resource.immediate[1]==SIZE_MAX) {
                    // Real control flow selects one constant descriptor per
                    // invocation. WARP additionally needs scalar alias declarations.
                    if (resource.type!=30 || op<169 || op>189) break;
                    if (temporary>=4096 || decl.high==UINT32_MAX ||
                        (atomics_only && decl.high-decl.low>=65536) ||
                        (resource.representation[1]!=2 && resource.representation[1]!=3)) return false;
                    size_t relative=resource.begin[1];
                    uint32_t base=0;
                    if (resource.representation[1]==3) base=code[relative++];
                    Words lowered={0,0x00100012,temporary}; // iadd scratch.x, relative, base
                    lowered.insert(lowered.end(),code.begin()+relative,code.begin()+resource.end[1]);
                    lowered.insert(lowered.end(),{0x00004001,base});
                    lowered[0]=30u|uint32_t(lowered.size()<<24);
                    lowered.insert(lowered.end(),{0x0300004c,0x0010000a,temporary}); // switch
                    for (uint32_t index=decl.low;index<=decl.high;++index) {
                        size_t a=0;
                        while (a<aliases.size() && (aliases[a].declaration!=d || aliases[a].index!=index)) ++a;
                        if (!atomics_only && a==aliases.size()) {
                            if (next_uav==UINT32_MAX) return false;
                            aliases.push_back({d,index,next_uav++});
                        }
                        lowered.insert(lowered.end(),{0x03000006,0x00004001,index}); // case
                        Words body(code.begin()+at,code.begin()+resource.begin[1]);
                        body[operand_at-at]&=~(7u<<25); // immediate32 descriptor index
                        size_t extension=operand_at;
                        while (code[extension]&0x80000000u) {
                            ++extension;
                            body[extension-at]&=~(1u<<17); // scalar descriptor is uniform
                        }
                        if (!atomics_only) body[resource.immediate[0]-at]=aliases[a].id;
                        body.push_back(index);
                        body.insert(body.end(),code.begin()+resource.end[1],code.begin()+end);
                        if (body.size()>127) return false;
                        body[0]=(body[0]&0x80ffffffu)|uint32_t(body.size()<<24);
                        lowered.insert(lowered.end(),body.begin(),body.end());
                        lowered.push_back(0x01000002); // break
                    }
                    lowered.push_back(0x01000017); // endswitch
                    replacements.push_back({at,lowered});
                    break;
                }
                if (atomics_only) break;
                uint32_t index=code[resource.immediate[1]];
                if (index<decl.low || index>decl.high) return false;
                size_t a=0;
                while (a<aliases.size() && (aliases[a].declaration!=d || aliases[a].index!=index)) ++a;
                if (a==aliases.size()) {
                    uint32_t &next=resource.type==7?next_srv:next_uav;
                    if (next==UINT32_MAX) return false;
                    aliases.push_back({d,index,next++});
                }
                code[resource.immediate[0]]=aliases[a].id;
                break;
            }
        }
    }
    if (aliases.empty() && replacements.empty()) return true;
    Words result(code.begin(),code.begin()+2);
    if (!replacements.empty() && !has_temporaries) result.insert(result.end(),{0x02000068,temporary+1});
    for (size_t at=2,end,payload;at<code.size();at=end) {
        if (!instruction(code,at,end,payload)) return false;
        const Words *replacement=nullptr;
        for (const auto &item:replacements) if (item.at==at) replacement=&item.words;
        if (replacement) result.insert(result.end(),replacement->begin(),replacement->end());
        else result.insert(result.end(),code.begin()+at,code.begin()+end);
        uint32_t op=code[at]&2047;
        if (op==104 && !replacements.empty()) result.back()=temporary+1;
        if (!(op==157 || op==158 || op==161 || op==162)) continue;
        Operand original;
        if (!operand(code,payload,end,original)) return false;
        for (const auto &alias:aliases) {
            const auto &decl=declarations[alias.declaration];
            if (decl.type!=original.type || decl.id!=code[original.immediate[0]]) continue;
            Words scalar=decl.words;
            size_t cursor=1; Operand target;
            if (!operand(scalar,cursor,scalar.size(),target)) return false;
            scalar[target.immediate[0]]=alias.id;
            scalar[target.immediate[1]]=scalar[target.immediate[2]]=alias.index;
            scalar.back()=decl.space+ZENIT_D12_STATIC_BUFFER_SPACE_OFFSET;
            result.insert(result.end(),scalar.begin(),scalar.end());
        }
    }
    if (result.size()>UINT32_MAX) return false;
    result[1]=uint32_t(result.size()); code.swap(result); changed=true;
    return true;
}

static HRESULT blob(ID3DBlob *input, ID3DBlob **output, bool atomics_only=false) {
    *output=nullptr;
    size_t size=input->GetBufferSize();
    if (size<32 || size>UINT32_MAX-128 || size%4) return E_INVALIDARG;
    const auto *data=(const uint32_t *)input->GetBufferPointer();
    if (data[0]!=0x43425844 || data[6]!=size || data[7]>(size-32)/4) return E_INVALIDARG;
    size_t count=data[7],header=8+count;
    Words result(data,data+header);
    bool changed=false;
    for (size_t part=0;part<count;++part) {
        size_t offset=data[8+part];
        if (offset%4 || offset<header*4 || offset>size-8) return E_INVALIDARG;
        const auto *chunk=data+offset/4;
        size_t length=chunk[1];
        if (length%4 || length>size-offset-8 || result.size()>UINT32_MAX/4) return E_INVALIDARG;
        result[8+part]=uint32_t(result.size()*4);
        Words contents(chunk+2,chunk+2+length/4);
        if (chunk[0]==0x58454853) { // SHEX
            bool rewritten=false;
            if (!rewrite(contents,rewritten,atomics_only)) return E_INVALIDARG;
            changed|=rewritten;
        }
        result.push_back(chunk[0]); result.push_back(uint32_t(contents.size()*4));
        result.insert(result.end(),contents.begin(),contents.end());
    }
    if (!changed) return S_OK;
    if (result.size()>UINT32_MAX/4) return E_INVALIDARG;
    result[6]=uint32_t(result.size()*4);
    // Verify the checksum algorithm against the original compiler output before
    // signing the rewritten container. No reflection/signature chunks change.
    BYTE original_hash[16];
    zenit_dxbc_digest::ComputeHashRetail((const BYTE *)data+20,UINT(size-20),original_hash);
    if (memcmp(original_hash,data+1,16)!=0) return E_FAIL;
    zenit_dxbc_digest::ComputeHashRetail((const BYTE *)result.data()+20,UINT(result.size()*4-20),(BYTE *)(result.data()+1));
    HRESULT hr=D3DCreateBlob(result.size()*4,output);
    if (SUCCEEDED(hr)) memcpy((*output)->GetBufferPointer(),result.data(),result.size()*4);
    return hr;
}
} // namespace zenit_warp
