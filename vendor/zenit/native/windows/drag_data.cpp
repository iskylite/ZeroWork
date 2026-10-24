// OLE outgoing payload storage. Session/preview setup is owned by the window.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <ole2.h>
#include <shlobj.h>
#include <wincodec.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifndef ZENIT_PLACEMENT_NEW
#define ZENIT_PLACEMENT_NEW
inline void *operator new(size_t,void *storage) noexcept {return storage;}
#endif
#include "drag_data.h"
static const size_t source_payload_cap=1024*1024, source_storage_cap=128*1024*1024;
static HGLOBAL clone_global(HGLOBAL original) {
    size_t size=GlobalSize(original);if(!size||size>source_storage_cap)return nullptr;
    const void *from=GlobalLock(original);if(!from)return nullptr;
    HGLOBAL copy=GlobalAlloc(GMEM_MOVEABLE,size);void *to=copy?GlobalLock(copy):nullptr;
    if(to){memcpy(to,from,size);GlobalUnlock(copy);}else{if(copy)GlobalFree(copy);copy=nullptr;}
    GlobalUnlock(original);return copy;
}
static wchar_t *to_wide(const char *bytes,size_t length,size_t *units) {
    if(!bytes||!length||length>source_payload_cap)return nullptr;
    int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,bytes,(int)length,nullptr,0);
    if(count<=0)return nullptr;
    wchar_t *wide=(wchar_t *)malloc(((size_t)count+1)*2);
    if(!wide)return nullptr;
    if(MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,bytes,(int)length,wide,count)!=count){free(wide);return nullptr;}
    wide[count]=0;*units=count;return wide;
}
static bool separator(wchar_t c){return c=='/'||c=='\\';}
static bool absolute_file(const wchar_t *path,size_t n) {
    if(!n||n>32767)return false;
    for(size_t i=0;i<n;++i)if(!path[i]||path[i]=='\r'||path[i]=='\n')return false;
    if(n>=3&&((path[0]>='A'&&path[0]<='Z')||(path[0]>='a'&&path[0]<='z'))&&path[1]==':'&&separator(path[2]))return true;
    if(n>=7&&path[0]=='\\'&&path[1]=='\\'&&path[2]=='?'&&path[3]=='\\') {
        if(n>=7&&path[5]==':'&&separator(path[6]))return absolute_file(path+4,n-4);
        if(n>=8&&_wcsnicmp(path+4,L"UNC\\",4)==0){
            size_t share=8;while(share<n&&!separator(path[share]))++share;
            return share>8&&share+1<n&&!separator(path[share+1]);
        }else return false;
    }
    if(n<5||!separator(path[0])||!separator(path[1]))return false;
    size_t share=2;while(share<n&&!separator(path[share]))++share;
    return share>2&&share+1<n&&!separator(path[share+1]);
}
static int hex_digit(char c){return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:c>='A'&&c<='F'?c-'A'+10:-1;}
static char *file_uri_path(const char *uri,size_t length,size_t *out_length) {
    if(length<8||_strnicmp(uri,"file://",7)!=0)return nullptr;
    const char *path=uri+7;size_t count=length-7;bool remote=false;
    if(count&&path[0]=='/'){++path;--count;}
    else {
        size_t host=0;while(host<count&&path[host]!='/')++host;
        if(!host||host==count)return nullptr;
        if(host==9&&_strnicmp(path,"localhost",9)==0){path+=host+1;count-=host+1;}
        else {remote=true;for(size_t i=0;i<host;++i)if(path[i]==':'||path[i]=='@'||path[i]=='%'||path[i]=='\\')return nullptr;}
    }
    char *decoded=(char *)malloc(count+3);if(!decoded)return nullptr;
    size_t used=0;if(remote){decoded[used++]='\\';decoded[used++]='\\';}
    for(size_t i=0;i<count;++i) {
        char c=path[i];
        if(c=='?'||c=='#'){free(decoded);return nullptr;}
        if(c=='%'){if(i+2>=count){free(decoded);return nullptr;}int a=hex_digit(path[i+1]),b=hex_digit(path[i+2]);if(a<0||b<0){free(decoded);return nullptr;}c=(char)((a<<4)|b);i+=2;}
        if(!c){free(decoded);return nullptr;}decoded[used++]=c;
    }
    decoded[used]=0;*out_length=used;return decoded;
}
class ZenitDragData final: public IDataObject {
    LONG refs=1;
    struct Slot {CLIPFORMAT format;HGLOBAL data;size_t size;DWORD medium_type;size_t stream_length;} slots[32]={};
    unsigned count=0,primary_count=0;
    size_t total=0;
    int find(CLIPFORMAT f)const {for(unsigned i=0;i<count;++i)if(slots[i].format==f)return (int)i;return -1;}
public:
    ~ZenitDragData(){for(unsigned i=0;i<count;++i)GlobalFree(slots[i].data);}
    bool add(CLIPFORMAT format,const void *bytes,size_t length) {
        if(!format||!bytes||!length||count==32||length>source_storage_cap-total)return false;
        HGLOBAL data=GlobalAlloc(GMEM_MOVEABLE|GMEM_ZEROINIT,length);
        size_t allocated=data?GlobalSize(data):0;
        if(!allocated||allocated>source_storage_cap-total){if(data)GlobalFree(data);return false;}
        void *p=GlobalLock(data);
        if(!p){if(data)GlobalFree(data);return false;}memcpy(p,bytes,length);GlobalUnlock(data);
        slots[count++]={format,data,allocated,TYMED_HGLOBAL,0};total+=allocated;return true;
    }
    void seal(){primary_count=count;}
    unsigned drop_operation(unsigned reported,unsigned allowed) {
        allowed&=7;reported&=7;
        unsigned fallback=(reported==1||reported==2||reported==4)?reported&allowed:0;
        const wchar_t *names[]={L"Logical Performed DropEffect",L"Performed DropEffect"};
        for(unsigned i=0;i<2;++i) {
            int index=find((CLIPFORMAT)RegisterClipboardFormatW(names[i]));
            if(index<0||slots[index].medium_type!=TYMED_HGLOBAL||slots[index].size<sizeof(DWORD))continue;
            const void *bytes=GlobalLock(slots[index].data);if(!bytes)continue;
            DWORD operation=0;memcpy(&operation,bytes,sizeof(operation));GlobalUnlock(slots[index].data);
            // Performed NONE means Shell already handled source removal for an
            // optimized move; it is not a logical cancellation notification.
            if(operation==0){if(i==0)return 0;continue;}
            operation&=7;
            if((operation==1||operation==2||operation==4)&&(operation&allowed))return operation;
        }
        return fallback;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void **out) override {
        if(!out)return E_POINTER;*out=nullptr;
        if(iid==IID_IUnknown||iid==IID_IDataObject){*out=(IDataObject *)this;AddRef();return S_OK;}return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override{return InterlockedIncrement(&refs);}
    ULONG STDMETHODCALLTYPE Release() override {ULONG n=InterlockedDecrement(&refs);if(!n){this->~ZenitDragData();free(this);}return n;}
    HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC *f) override {
        if(!f)return E_POINTER;
        if(f->dwAspect!=DVASPECT_CONTENT)return DV_E_DVASPECT;
        if(f->lindex!=-1)return DV_E_LINDEX;
        int index=find(f->cfFormat);if(index<0)return DV_E_FORMATETC;
        return f->tymed&slots[index].medium_type?S_OK:DV_E_TYMED;
    }
    HRESULT STDMETHODCALLTYPE GetData(FORMATETC *f,STGMEDIUM *out) override {
        if(!out)return E_POINTER;*out={};HRESULT hr=QueryGetData(f);if(FAILED(hr))return hr;
        const Slot &slot=slots[find(f->cfFormat)];
        HGLOBAL copy=clone_global(slot.data);if(!copy)return E_OUTOFMEMORY;
        if(slot.medium_type==TYMED_ISTREAM) {
            IStream *stream=nullptr;HRESULT result=CreateStreamOnHGlobal(copy,TRUE,&stream);
            if(FAILED(result)){GlobalFree(copy);return result;}
            ULARGE_INTEGER size={};size.QuadPart=slot.stream_length;
            result=stream->SetSize(size);if(FAILED(result)){stream->Release();return result;}
            out->tymed=TYMED_ISTREAM;out->pstm=stream;
        }else {out->tymed=TYMED_HGLOBAL;out->hGlobal=copy;}return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC *,STGMEDIUM *) override{return E_NOTIMPL;}
    HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC *f,FORMATETC *out) override {if(!f||!out)return E_POINTER;*out=*f;out->ptd=nullptr;return DATA_S_SAMEFORMATETC;}
    HRESULT STDMETHODCALLTYPE SetData(FORMATETC *f,STGMEDIUM *medium,BOOL release) override {
        if(!f||!medium)return E_POINTER;
        if(f->dwAspect!=DVASPECT_CONTENT)return DV_E_DVASPECT;
        if(f->lindex!=-1)return DV_E_LINDEX;
        if(!(f->tymed&medium->tymed)||(medium->tymed!=TYMED_HGLOBAL&&medium->tymed!=TYMED_ISTREAM))return DV_E_TYMED;
        int index=find(f->cfFormat);if(index>=0&&(unsigned)index<primary_count)return E_ACCESSDENIED;
        size_t old=index>=0?slots[index].size:0,size=0,stream_length=0;HGLOBAL copy=nullptr;
        if(!f->cfFormat||(index<0&&count==32))return E_OUTOFMEMORY;
        if(medium->tymed==TYMED_HGLOBAL) {
            if(!medium->hGlobal)return DV_E_TYMED;
            size=GlobalSize(medium->hGlobal);
            if(!size||size>source_storage_cap-(total-old))return E_OUTOFMEMORY;
            copy=clone_global(medium->hGlobal);if(!copy)return E_OUTOFMEMORY;
        }else {
            if(!medium->pstm)return DV_E_TYMED;
            STATSTG stat={};HRESULT hr=medium->pstm->Stat(&stat,STATFLAG_NONAME);if(FAILED(hr))return hr;
            if(stat.cbSize.QuadPart>source_storage_cap-(total-old))return E_OUTOFMEMORY;
            stream_length=(size_t)stat.cbSize.QuadPart;
            // IStream::Clone shares contents, so snapshot its bytes as well as
            // its independent seek position. Never seek the caller's stream.
            IStream *reader=nullptr;hr=medium->pstm->Clone(&reader);if(FAILED(hr))return hr;
            LARGE_INTEGER zero={};hr=reader->Seek(zero,STREAM_SEEK_SET,nullptr);
            if(SUCCEEDED(hr)){copy=GlobalAlloc(GMEM_MOVEABLE|GMEM_ZEROINIT,stream_length?stream_length:1);if(!copy)hr=E_OUTOFMEMORY;}
            BYTE *destination=copy?(BYTE *)GlobalLock(copy):nullptr;
            if(copy&&!destination)hr=E_OUTOFMEMORY;
            if(SUCCEEDED(hr)&&stream_length){ULONG read=0;hr=reader->Read(destination,(ULONG)stream_length,&read);if(SUCCEEDED(hr)&&read!=stream_length)hr=STG_E_READFAULT;}
            if(destination)GlobalUnlock(copy);reader->Release();
            if(FAILED(hr)){if(copy)GlobalFree(copy);return hr;}size=GlobalSize(copy);
            if(size>source_storage_cap-(total-old)){GlobalFree(copy);return E_OUTOFMEMORY;}
        }
        if(index<0)index=(int)count++;else GlobalFree(slots[index].data);
        slots[index]={f->cfFormat,copy,size,medium->tymed,stream_length};total=total-old+size;
        if(release)ReleaseStgMedium(medium);return S_OK;
    }
    HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD direction,IEnumFORMATETC **out) override {
        if(!out)return E_POINTER;*out=nullptr;if(direction!=DATADIR_GET)return E_NOTIMPL;
        FORMATETC formats[32];for(unsigned i=0;i<count;++i)formats[i]={slots[i].format,nullptr,DVASPECT_CONTENT,-1,slots[i].medium_type};
        return SHCreateStdEnumFmtEtc(count,formats,out);
    }
    HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC *,DWORD,IAdviseSink *,DWORD *) override{return OLE_E_ADVISENOTSUPPORTED;}
    HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override{return OLE_E_ADVISENOTSUPPORTED;}
    HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA **) override{return OLE_E_ADVISENOTSUPPORTED;}
};
extern "C" void *zenit_drag_data_create(unsigned kind,const char *bytes,size_t length) {
    if(kind>2||!bytes||!length||length>source_payload_cap)return nullptr;
    size_t units=0;wchar_t *wide=to_wide(bytes,length,&units);if(!wide)return nullptr;
    void *memory=malloc(sizeof(ZenitDragData));if(!memory){free(wide);return nullptr;}
    ZenitDragData *data=new(memory)ZenitDragData;bool ok=false;
    if(kind==2) {
        char *encoded=(char *)malloc(length+4);if(encoded){uint32_t n=(uint32_t)length;memcpy(encoded,&n,4);memcpy(encoded+4,bytes,length);ok=data->add((CLIPFORMAT)RegisterClipboardFormatW(L"Zenit.Internal.UTF8.v1"),encoded,length+4);free(encoded);}
    } else if(!memchr(bytes,0,length)) {
        ok=data->add(CF_UNICODETEXT,wide,(units+1)*2);
        if(kind==1&&ok) {
            bool is_uri=length>=7&&_strnicmp(bytes,"file://",7)==0;wchar_t *file=wide;size_t file_units=units;
            if(is_uri){size_t decoded_length=0;char *decoded=file_uri_path(bytes,length,&decoded_length);file=decoded?to_wide(decoded,decoded_length,&file_units):nullptr;free(decoded);}
            if(file&&absolute_file(file,file_units)) {
                size_t size=sizeof(DROPFILES)+(file_units+2)*2;BYTE *drop=(BYTE *)calloc(1,size);
                if(drop){DROPFILES header={};header.pFiles=sizeof(header);header.fWide=TRUE;memcpy(drop,&header,sizeof(header));wchar_t *names=(wchar_t *)(drop+sizeof(header));for(size_t i=0;i<file_units;++i)names[i]=file[i]=='/'?L'\\':file[i];ok=data->add(CF_HDROP,drop,size);free(drop);
                    if(ok&&is_uri)ok=data->add((CLIPFORMAT)RegisterClipboardFormatW(L"UniformResourceLocatorW"),wide,(units+1)*2);}else ok=false;
            } else if(!is_uri&&wcsstr(wide,L"://"))ok=data->add((CLIPFORMAT)RegisterClipboardFormatW(L"UniformResourceLocatorW"),wide,(units+1)*2);
            else ok=false;
            if(is_uri)free(file);
        }
    }
    free(wide);if(!ok){data->Release();return nullptr;}data->seal();return data;
}
extern "C" unsigned zenit_drag_data_drop_operation(void *object,unsigned reported,unsigned allowed) {
    if(!object)return 0;
    return static_cast<ZenitDragData *>((IDataObject *)object)->drop_operation(reported,allowed);
}

template<class T> struct PreviewCom {
    T *p=nullptr;
    ~PreviewCom(){if(p)p->Release();}
};
extern "C" void *zenit_drag_preview_bitmap(const unsigned char *png,size_t length,unsigned width,unsigned height) {
    if(!png||length<8||length>16*1024*1024||memcmp(png,"\x89PNG\r\n\x1a\n",8)||
       !width||!height||width>4096||height>4096)return nullptr;
    PreviewCom<IWICImagingFactory> factory;
    if(FAILED(CoCreateInstance(CLSID_WICImagingFactory,nullptr,CLSCTX_INPROC_SERVER,IID_IWICImagingFactory,(void **)&factory.p)))return nullptr;
    PreviewCom<IWICStream> stream;
    PreviewCom<IWICBitmapDecoder> decoder;
    PreviewCom<IWICBitmapFrameDecode> frame;
    PreviewCom<IWICBitmapScaler> scaler;
    PreviewCom<IWICFormatConverter> converter;
    if(FAILED(factory.p->CreateStream(&stream.p))||
       FAILED(stream.p->InitializeFromMemory(const_cast<BYTE *>(png),(DWORD)length))||
       FAILED(factory.p->CreateDecoderFromStream(stream.p,nullptr,WICDecodeMetadataCacheOnLoad,&decoder.p)))return nullptr;
    GUID container={};UINT source_width=0,source_height=0;
    if(FAILED(decoder.p->GetContainerFormat(&container))||container!=GUID_ContainerFormatPng||
       FAILED(decoder.p->GetFrame(0,&frame.p))||FAILED(frame.p->GetSize(&source_width,&source_height))||
       !source_width||!source_height||(uint64_t)source_width*source_height>16*1024*1024)return nullptr;
    if(FAILED(factory.p->CreateBitmapScaler(&scaler.p))||
       FAILED(scaler.p->Initialize(frame.p,width,height,WICBitmapInterpolationModeFant))||
       FAILED(factory.p->CreateFormatConverter(&converter.p))||
       FAILED(converter.p->Initialize(scaler.p,GUID_WICPixelFormat32bppBGRA,WICBitmapDitherTypeNone,nullptr,0,WICBitmapPaletteTypeCustom)))return nullptr;
    // Shell's InitializeFromBitmap premultiplies RGB itself. Supplying PBGRA
    // here would multiply translucent preview colors twice.
    BITMAPINFO info={};info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth=(LONG)width;info.bmiHeader.biHeight=-(LONG)height;
    info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;info.bmiHeader.biCompression=BI_RGB;
    void *pixels=nullptr;HBITMAP bitmap=CreateDIBSection(nullptr,&info,DIB_RGB_COLORS,&pixels,nullptr,0);
    if(!bitmap||!pixels){if(bitmap)DeleteObject(bitmap);return nullptr;}
    if(FAILED(converter.p->CopyPixels(nullptr,width*4,width*height*4,(BYTE *)pixels))){DeleteObject(bitmap);return nullptr;}
    return bitmap;
}
