#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <ole2.h>
#include <shellapi.h>
#include <shlobj.h>
#include <stddef.h>
#ifndef ZENIT_PLACEMENT_NEW
#define ZENIT_PLACEMENT_NEW
inline void *operator new(size_t,void *storage) noexcept { return storage; }
#endif
#include <stdlib.h>
#include <string.h>
#include "drop_bridge.h"

static const size_t payload_cap=1024*1024, queued_cap=4*payload_cap;
struct Bytes {
    char *data=nullptr;
    size_t size=0;
    bool truncated=false;
    ~Bytes(){free(data);}
    bool append(const wchar_t *text,size_t units,bool separator=false) {
        int n=units ? WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,text,(int)units,nullptr,0,nullptr,nullptr) : 0;
        if (units && n<=0) return false;
        size_t extra=(size_t)n+(separator?1:0);
        if (extra>payload_cap-size) {truncated=true;return false;}
        char *next=(char *)realloc(data,size+extra+1);
        if (!next) return false;
        data=next;
        if (separator) data[size++]='\n';
        if (n && WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,text,(int)units,data+size,n,nullptr,nullptr)!=n) return false;
        size+=(size_t)n;data[size]=0;return true;
    }
};

// Bound all scans by GlobalSize. Shell data is supplied by another process;
// never pass malformed DROPFILES buffers to an unbounded string parser.
static bool read_data(IDataObject *object,CLIPFORMAT format,unsigned kind,Bytes &out) {
    FORMATETC request={format,nullptr,DVASPECT_CONTENT,-1,TYMED_HGLOBAL};
    STGMEDIUM medium={};
    if (FAILED(object->GetData(&request,&medium))) return false;
    bool ok=false;
    if (medium.tymed==TYMED_HGLOBAL && medium.hGlobal) {
        size_t size=GlobalSize(medium.hGlobal);
        if (size>4*payload_cap) out.truncated=true;
        else {
            const BYTE *bytes=(const BYTE *)GlobalLock(medium.hGlobal);
            if (bytes) {
                if (kind==1 && format==CF_HDROP && size>=sizeof(DROPFILES)) {
                    DROPFILES header;memcpy(&header,bytes,sizeof(header));
                    size_t offset=header.pFiles;
                    if (offset>=sizeof(header) && offset<size && (!header.fWide || offset%2==0)) {
                        bool first=true,terminated=false;
                        while (offset<size) {
                            size_t remaining=size-offset,units=0;
                            if (header.fWide) {
                                if (remaining<2) break;
                                const wchar_t *text=(const wchar_t *)(bytes+offset);
                                while (units<remaining/2 && text[units]) ++units;
                                if (units==remaining/2) break;
                                if (!units) {terminated=!first;break;}
                                bool newline=false;
                                for(size_t i=0;i<units;++i) newline|=text[i]=='\n'||text[i]=='\r';
                                if (newline || !out.append(text,units,!first)) break;
                                offset+=(units+1)*2;
                            } else {
                                const char *text=(const char *)(bytes+offset);
                                while(units<remaining && text[units]) ++units;
                                if(units==remaining) break;
                                if(!units){terminated=!first;break;}
                                if(memchr(text,'\n',units)||memchr(text,'\r',units))break;
                                int count=MultiByteToWideChar(CP_ACP,0,text,(int)units,nullptr,0);
                                wchar_t *wide=count>0?(wchar_t *)malloc((size_t)count*2):nullptr;
                                bool converted=wide && MultiByteToWideChar(CP_ACP,0,text,(int)units,wide,count)==count && out.append(wide,count,!first);
                                free(wide);if(!converted)break;
                                offset+=units+1;
                            }
                            first=false;
                        }
                        ok=terminated;
                    }
                } else if (kind==3 && size>=4) {
                    uint32_t length;memcpy(&length,bytes,4);
                    if(length>payload_cap)out.truncated=true;
                    else if(length<=size-4 && (!length || MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,(const char *)bytes+4,(int)length,nullptr,0)>0)) {
                        out.data=(char *)malloc((size_t)length+1);
                        if(out.data){memcpy(out.data,bytes+4,length);out.data[length]=0;out.size=length;ok=true;}
                    }
                } else if (kind==2 || kind==1) {
                    if(size%2==0) {
                        const wchar_t *wide=(const wchar_t *)bytes;size_t count=0;
                        while(count<size/2 && wide[count])++count;
                        if(count<size/2)ok=out.append(wide,count);
                    }
                }
                GlobalUnlock(medium.hGlobal);
            }
        }
    }
    ReleaseStgMedium(&medium);
    return ok;
}

class Target final: public IDropTarget {
    LONG refs=1;
    HWND hwnd;
    uint64_t (*next_serial)(void *);
    void *context;
    unsigned allowed=1;
    CLIPFORMAT format=0;
    unsigned payload_kind=0;
    bool entered=false;
    POINTL last={};
    ZenitDragPacket queue[128]={};
    unsigned head=0,count=0;
    size_t queued_bytes=0;
    CLIPFORMAT url_format,internal_format;
    IDropTargetHelper *helper=nullptr;
    bool push(unsigned kind,POINTL point,unsigned operation=0,Bytes *payload=nullptr) {
        if(!hwnd || !next_serial)return false;
        // Reserve terminal space for an accepted enter, and coalesce adjacent
        // motion only. Each replacement receives a fresh global input serial.
        bool replace=kind==1 && count && queue[(head+count-1)%128].kind==1;
        if((!replace && (count==128 || (kind<2 && count>=126))) || (payload && payload->size>queued_cap-queued_bytes))return false;
        POINT client={point.x,point.y};
        if(!ScreenToClient(hwnd,&client))return false;
        float scale=(float)GetDpiForWindow(hwnd)/96.0f;
        ZenitDragPacket &p=queue[(head+count-(replace?1:0))%128];
        p={client.x/scale,client.y/scale,kind,payload_kind,payload && payload->truncated?1u:0u,operation,
           payload?payload->data:nullptr,payload?payload->size:0,next_serial(context)};
        if(payload){queued_bytes+=payload->size;payload->data=nullptr;payload->size=0;}
        if(!replace)++count;InvalidateRect(hwnd,nullptr,FALSE);return true;
    }
    DWORD effect(DWORD source,DWORD keys) {
        DWORD choices=source&allowed&7;
        if(!hwnd || !format)return DROPEFFECT_NONE;
        DWORD wanted=(keys&MK_CONTROL)&&(keys&MK_SHIFT)?4:(keys&MK_SHIFT)?2:(keys&MK_CONTROL)?1:
            (choices&2)?2:(choices&1)?1:(choices&4)?4:0;
        return choices&wanted;
    }
    void choose(IDataObject *object) {
        format=0;payload_kind=0;
        CLIPFORMAT formats[]={CF_HDROP,url_format,internal_format,CF_UNICODETEXT};
        for(unsigned i=0;i<4;++i) {
            if(!formats[i])continue;
            FORMATETC f={formats[i],nullptr,DVASPECT_CONTENT,-1,TYMED_HGLOBAL};
            if(object->QueryGetData(&f)==S_OK){format=formats[i];payload_kind=i==3?2:i==2?3:1;break;}
        }
    }
public:
    Target(HWND window,uint64_t (*serial)(void *),void *ctx):hwnd(window),next_serial(serial),context(ctx) {
        url_format=(CLIPFORMAT)RegisterClipboardFormatW(L"UniformResourceLocatorW");
        internal_format=(CLIPFORMAT)RegisterClipboardFormatW(L"Zenit.Internal.UTF8.v1");
#ifndef ZENIT_DROP_TEST_ONLY
        CoCreateInstance(CLSID_DragDropHelper,nullptr,CLSCTX_INPROC_SERVER,IID_IDropTargetHelper,(void **)&helper);
#endif
    }
    ~Target(){while(count)consume(queue[head].serial);if(helper)helper->Release();}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void **out) override {
        if(!out)return E_POINTER;*out=nullptr;
        if(iid==IID_IUnknown || iid==IID_IDropTarget){*out=(IDropTarget *)this;AddRef();return S_OK;}return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override {return InterlockedIncrement(&refs);}
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG n=InterlockedDecrement(&refs);if(!n){this->~Target();free(this);}return n;
    }
    HRESULT STDMETHODCALLTYPE DragEnter(IDataObject *object,DWORD keys,POINTL point,DWORD *result) override {
        if(!object||!result)return E_INVALIDARG;
        choose(object);last=point;*result=effect(*result,keys);
        entered=push(0,point);if(!entered){*result=0;format=0;}
        if(helper&&entered){POINT p={point.x,point.y};helper->DragEnter(hwnd,object,&p,*result);}
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DragOver(DWORD keys,POINTL point,DWORD *result) override {
        if(!result)return E_INVALIDARG;
        last=point;*result=effect(*result,keys);
        if(!entered || !push(1,point)) *result=0;
        if(helper&&entered){POINT p={point.x,point.y};helper->DragOver(&p,*result);}
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DragLeave() override {if(entered)push(2,last);if(helper)helper->DragLeave();entered=false;format=0;payload_kind=0;return S_OK;}
    HRESULT STDMETHODCALLTYPE Drop(IDataObject *object,DWORD keys,POINTL point,DWORD *result) override {
        if(!object||!result)return E_INVALIDARG;
        if(!entered){*result=0;if(helper)helper->DragLeave();return S_OK;}
        choose(object);DWORD selected=effect(*result,keys);Bytes bytes;
        if(selected && read_data(object,format,payload_kind,bytes)) {
            if(!push(3,point,selected,&bytes)){selected=0;push(2,point);}
        } else {
            selected=0;
            if(bytes.truncated){free(bytes.data);bytes.data=nullptr;bytes.size=0;push(3,point,0,&bytes);}
            else push(2,point);
        }
        if(helper){POINT p={point.x,point.y};helper->Drop(object,&p,selected);}
        *result=selected;entered=false;format=0;payload_kind=0;return S_OK;
    }
    bool peek(ZenitDragPacket *out){if(!count)return false;*out=queue[head];return true;}
    bool consume(uint64_t serial) {
        if(!count || queue[head].serial!=serial)return false;
        queued_bytes-=queue[head].length;free((void *)queue[head].bytes);queue[head]={};head=(head+1)%128;--count;return true;
    }
    bool set(unsigned operations){if(operations&~7u)return false;allowed=operations;return true;}
    HWND detach(){HWND window=hwnd;hwnd=nullptr;context=nullptr;next_serial=nullptr;allowed=0;entered=false;if(helper)helper->DragLeave();return window;}
};

#ifndef ZENIT_DROP_TEST_ONLY
extern "C" void *zenit_drop_create(void *hwnd,uint64_t (*serial)(void *),void *context) {
    if(!hwnd||!serial||FAILED(OleInitialize(nullptr)))return nullptr;
    void *memory=malloc(sizeof(Target));
    if(!memory){OleUninitialize();return nullptr;}
    Target *target=new(memory)Target((HWND)hwnd,serial,context);
    if(FAILED(RegisterDragDrop((HWND)hwnd,target))){target->Release();OleUninitialize();return nullptr;}
    return target;
}
extern "C" void zenit_drop_destroy(void *state) {
    if(!state)return;Target *target=(Target *)state;
    // OLE may retain a reference until its active drag ends. Invalidate the
    // callback context before releasing our window and its input serial owner.
    RevokeDragDrop(target->detach());target->Release();OleUninitialize();
}
extern "C" int zenit_drop_set_operations(void *state,unsigned operations){return state && ((Target *)state)->set(operations);}
extern "C" int zenit_drop_peek(void *state,ZenitDragPacket *packet){return state && packet && ((Target *)state)->peek(packet);}
extern "C" int zenit_drop_consume(void *state,uint64_t serial){return state && ((Target *)state)->consume(serial);}
#endif
