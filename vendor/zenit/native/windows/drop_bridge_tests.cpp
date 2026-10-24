// Standalone native robustness probe; uses hostile HGLOBAL data, not UI input.
#define ZENIT_DROP_TEST_ONLY
#include "drop_bridge.cpp"
#include "drag_data.cpp"
#include <stdio.h>
class Data final: public IDataObject {
public:
    CLIPFORMAT format;const void *bytes;size_t size;unsigned reads=0;
    Data(CLIPFORMAT f,const void *p,size_t n):format(f),bytes(p),size(n){}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void **out) override {if(!out)return E_POINTER;*out=nullptr;if(iid==IID_IUnknown||iid==IID_IDataObject){*out=this;return S_OK;}return E_NOINTERFACE;}
    ULONG STDMETHODCALLTYPE AddRef() override{return 1;}
    ULONG STDMETHODCALLTYPE Release() override{return 1;}
    HRESULT STDMETHODCALLTYPE GetData(FORMATETC *f,STGMEDIUM *m) override {
        if(QueryGetData(f)!=S_OK)return DV_E_FORMATETC;
        HGLOBAL h=GlobalAlloc(GMEM_MOVEABLE,size);if(!h)return E_OUTOFMEMORY;
        void *p=GlobalLock(h);if(!p){GlobalFree(h);return E_OUTOFMEMORY;}
        memcpy(p,bytes,size);GlobalUnlock(h);m->tymed=TYMED_HGLOBAL;m->hGlobal=h;m->pUnkForRelease=nullptr;++reads;return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC *,STGMEDIUM *) override{return E_NOTIMPL;}
    HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC *f) override{return f&&f->cfFormat==format&&(f->tymed&TYMED_HGLOBAL)?S_OK:DV_E_FORMATETC;}
    HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC *,FORMATETC *) override{return E_NOTIMPL;}
    HRESULT STDMETHODCALLTYPE SetData(FORMATETC *,STGMEDIUM *,BOOL) override{return E_NOTIMPL;}
    HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD,IEnumFORMATETC **) override{return E_NOTIMPL;}
    HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC *,DWORD,IAdviseSink *,DWORD *) override{return OLE_E_ADVISENOTSUPPORTED;}
    HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override{return OLE_E_ADVISENOTSUPPORTED;}
    HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA **) override{return OLE_E_ADVISENOTSUPPORTED;}
};
static unsigned checks=0,failed=0;
#define CHECK(x) do{++checks;if(!(x)){++failed;printf("FAIL line %d: %s\n",__LINE__,#x);}}while(0)
#include "a11y_snapshot_tests.h"
#include "accessibility_provider_tests.h"
static void verify(CLIPFORMAT format,unsigned kind,const void *p,size_t size,bool valid,const char *expected=nullptr,bool truncated=false){
    Data d(format,p,size);Bytes b;bool result=read_data(&d,format,kind,b);
    CHECK(result==valid);CHECK(b.truncated==truncated);CHECK(d.reads==1);
    if(expected){CHECK(b.size==strlen(expected));CHECK(b.size==0 || memcmp(b.data,expected,b.size)==0);}
}
static uint64_t serial(void *p){return ++*(uint64_t *)p;}
static void source_roundtrip(unsigned kind,const char *input,size_t length,CLIPFORMAT format,unsigned receiver_kind,const char *expected,size_t expected_length) {
    char *borrowed=(char *)malloc(length+1);memcpy(borrowed,input,length);borrowed[length]='!';
    IDataObject *object=(IDataObject *)zenit_drag_data_create(kind,borrowed,length);CHECK(object!=nullptr);
    memset(borrowed,'x',length);free(borrowed);if(!object)return;
    FORMATETC f={format,nullptr,DVASPECT_CONTENT,-1,TYMED_HGLOBAL};CHECK(object->QueryGetData(&f)==S_OK);
    Bytes b;CHECK(read_data(object,format,receiver_kind,b));CHECK(b.size==expected_length&&memcmp(b.data,expected,expected_length)==0);
    IEnumFORMATETC *enumerator=nullptr;CHECK(object->EnumFormatEtc(DATADIR_GET,&enumerator)==S_OK&&enumerator);
    if(enumerator){FORMATETC entry={};ULONG fetched=0;bool found=false;while(enumerator->Next(1,&entry,&fetched)==S_OK){found|=entry.cfFormat==format;CHECK(entry.tymed==TYMED_HGLOBAL&&entry.ptd==nullptr);}
        CHECK(found);IEnumFORMATETC *copy=nullptr;CHECK(enumerator->Reset()==S_OK&&enumerator->Clone(&copy)==S_OK);if(copy)copy->Release();enumerator->Release();}
    f.tymed=TYMED_ISTREAM;CHECK(object->QueryGetData(&f)==DV_E_TYMED);f.tymed=TYMED_HGLOBAL;f.lindex=0;CHECK(object->QueryGetData(&f)==DV_E_LINDEX);f.lindex=-1;f.dwAspect=DVASPECT_THUMBNAIL;CHECK(object->QueryGetData(&f)==DV_E_DVASPECT);
    object->Release();
}
class ReleaseOwner final: public IUnknown {
    HGLOBAL handle;unsigned *counter;
public:
    ReleaseOwner(HGLOBAL h,unsigned *n):handle(h),counter(n){}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID,void **out) override {if(out)*out=nullptr;return E_NOINTERFACE;}
    ULONG STDMETHODCALLTYPE AddRef() override{return 1;}
    ULONG STDMETHODCALLTYPE Release() override{++*counter;GlobalFree(handle);return 0;}
};
static void source_contract() {
    source_roundtrip(0,"中文 🧪\nline",strlen("中文 🧪\nline"),CF_UNICODETEXT,2,"中文 🧪\nline",strlen("中文 🧪\nline"));
    source_roundtrip(2,"内部\0🧪payload",sizeof("内部\0🧪payload")-1,(CLIPFORMAT)RegisterClipboardFormatW(L"Zenit.Internal.UTF8.v1"),3,"内部\0🧪payload",sizeof("内部\0🧪payload")-1);
    const char *paths[]={"C:\\输入-🧪.txt","\\\\server\\share\\file.txt","\\\\?\\C:\\long\\file.txt","\\\\?\\UNC\\server\\share\\file.txt"};
    for(const char *path:paths)source_roundtrip(1,path,strlen(path),CF_HDROP,1,path,strlen(path));
    source_roundtrip(1,"D:/folder/file.txt",18,CF_HDROP,1,"D:\\folder\\file.txt",18);
    source_roundtrip(1,"\\\\?\\C:\\",7,CF_HDROP,1,"\\\\?\\C:\\",7);
    const char *url="https://zenit.example/路径?q=🧪";
    source_roundtrip(1,url,strlen(url),(CLIPFORMAT)RegisterClipboardFormatW(L"UniformResourceLocatorW"),1,url,strlen(url));
    const char *uri="file:///C:/%E8%BE%93%E5%85%A5-%F0%9F%A7%AA.txt";
    source_roundtrip(1,uri,strlen(uri),(CLIPFORMAT)RegisterClipboardFormatW(L"UniformResourceLocatorW"),1,uri,strlen(uri));
    source_roundtrip(1,uri,strlen(uri),CF_HDROP,1,"C:\\输入-🧪.txt",strlen("C:\\输入-🧪.txt"));
    source_roundtrip(1,"file://localhost/D:/space%20name.txt",strlen("file://localhost/D:/space%20name.txt"),CF_HDROP,1,"D:\\space name.txt",strlen("D:\\space name.txt"));
    source_roundtrip(1,"file://server/share/a%23b.txt",strlen("file://server/share/a%23b.txt"),CF_HDROP,1,"\\\\server\\share\\a#b.txt",strlen("\\\\server\\share\\a#b.txt"));
    // File URLs must not silently truncate at MAX_PATH during conversion.
    char long_uri[512]="file:///C:/",long_path[512]="C:\\";
    memset(long_uri+11,'a',400);long_uri[411]=0;
    memset(long_path+3,'a',400);long_path[403]=0;
    source_roundtrip(1,long_uri,411,CF_HDROP,1,long_path,403);
    const char *invalid[]={"relative.txt","C:relative.txt","\\rooted.txt","\\\\server","file:///C:/%00.txt","file:///C:/%ff.txt","file:///C:/bad%xx.txt","file:///tmp/posix.txt","file:///C:/file.txt#fragment"};
    for(const char *p:invalid)CHECK(zenit_drag_data_create(1,p,strlen(p))==nullptr);
    CHECK(zenit_drag_data_create(0,"a\0b",3)==nullptr);CHECK(zenit_drag_data_create(0,"\xff",1)==nullptr);
    CHECK(zenit_drag_data_create(3,"x",1)==nullptr);CHECK(zenit_drag_data_create(0,"",0)==nullptr);
    char *oversized=(char *)malloc(source_payload_cap+1);memset(oversized,'x',source_payload_cap+1);
    CHECK(zenit_drag_data_create(0,oversized,source_payload_cap+1)==nullptr);
    CHECK(zenit_drag_data_create(2,oversized,source_payload_cap+1)==nullptr);free(oversized);
    IDataObject *object=(IDataObject *)zenit_drag_data_create(0,"original",8);CHECK(object!=nullptr);if(!object)return;
    FORMATETC f={CF_UNICODETEXT,nullptr,DVASPECT_CONTENT,-1,TYMED_HGLOBAL};STGMEDIUM first={},second={};
    CHECK(object->GetData(&f,&first)==S_OK&&object->GetData(&f,&second)==S_OK);CHECK(first.hGlobal!=second.hGlobal);
    wchar_t *mutated=(wchar_t *)GlobalLock(first.hGlobal);mutated[0]='X';GlobalUnlock(first.hGlobal);ReleaseStgMedium(&first);
    Bytes unchanged;CHECK(read_data(object,CF_UNICODETEXT,2,unchanged));CHECK(unchanged.size==8&&memcmp(unchanged.data,"original",8)==0);
    CLIPFORMAT custom=(CLIPFORMAT)RegisterClipboardFormatW(L"Zenit.Drag.Preview.Private.Test");FORMATETC private_f={custom,nullptr,DVASPECT_CONTENT,-1,TYMED_HGLOBAL};
    STGMEDIUM medium={};medium.tymed=TYMED_HGLOBAL;medium.hGlobal=GlobalAlloc(GMEM_MOVEABLE,4);char *p=(char *)GlobalLock(medium.hGlobal);memcpy(p,"ABCD",4);GlobalUnlock(medium.hGlobal);
    CHECK(object->SetData(&private_f,&medium,FALSE)==S_OK);p=(char *)GlobalLock(medium.hGlobal);p[0]='X';GlobalUnlock(medium.hGlobal);ReleaseStgMedium(&medium);
    STGMEDIUM private_copy={};CHECK(object->GetData(&private_f,&private_copy)==S_OK);p=(char *)GlobalLock(private_copy.hGlobal);CHECK(memcmp(p,"ABCD",4)==0);GlobalUnlock(private_copy.hGlobal);ReleaseStgMedium(&private_copy);
    unsigned releases=0;HGLOBAL h=GlobalAlloc(GMEM_MOVEABLE,4);p=(char *)GlobalLock(h);memcpy(p,"next",4);GlobalUnlock(h);ReleaseOwner owner(h,&releases);medium.tymed=TYMED_HGLOBAL;medium.hGlobal=h;medium.pUnkForRelease=&owner;
    CHECK(object->SetData(&f,&medium,TRUE)==E_ACCESSDENIED&&releases==0);
    CHECK(object->SetData(&private_f,&medium,TRUE)==S_OK&&releases==1);
    object->Release();wchar_t *survives=(wchar_t *)GlobalLock(second.hGlobal);CHECK(survives&&wcscmp(survives,L"original")==0);if(survives)GlobalUnlock(second.hGlobal);ReleaseStgMedium(&second);
    object=(IDataObject *)zenit_drag_data_create(0,"stream owner",12);CHECK(object!=nullptr);
    if(!object)return;
    IStream *stream=nullptr;CHECK(CreateStreamOnHGlobal(nullptr,TRUE,&stream)==S_OK);
    if(stream){
        ULONG written=0;CHECK(stream->Write("ABCD",4,&written)==S_OK&&written==4);
        LARGE_INTEGER position={};position.QuadPart=2;CHECK(stream->Seek(position,STREAM_SEEK_SET,nullptr)==S_OK);
        FORMATETC stream_f={custom,nullptr,DVASPECT_CONTENT,-1,TYMED_ISTREAM};
        STGMEDIUM supplied={};supplied.tymed=TYMED_ISTREAM;supplied.pstm=stream;
        CHECK(object->SetData(&stream_f,&supplied,FALSE)==S_OK);
        ULARGE_INTEGER cursor={};position.QuadPart=0;CHECK(stream->Seek(position,STREAM_SEEK_CUR,&cursor)==S_OK&&cursor.QuadPart==2);
        CHECK(stream->Seek(position,STREAM_SEEK_SET,nullptr)==S_OK);CHECK(stream->Write("XXXX",4,&written)==S_OK);stream->Release();
        STGMEDIUM snapshot={};CHECK(object->GetData(&stream_f,&snapshot)==S_OK&&snapshot.tymed==TYMED_ISTREAM);
        if(snapshot.pstm){char copied[4]={};ULONG read=0;CHECK(snapshot.pstm->Read(copied,4,&read)==S_OK&&read==4&&memcmp(copied,"ABCD",4)==0);ReleaseStgMedium(&snapshot);}
        stream_f.tymed=TYMED_HGLOBAL;CHECK(object->QueryGetData(&stream_f)==DV_E_TYMED);stream_f.tymed=TYMED_ISTREAM;
        CHECK(CreateStreamOnHGlobal(nullptr,TRUE,&stream)==S_OK);supplied.pstm=stream;
        CHECK(object->SetData(&stream_f,&supplied,TRUE)==S_OK);
        STGMEDIUM empty={};CHECK(object->GetData(&stream_f,&empty)==S_OK&&empty.tymed==TYMED_ISTREAM);
        object->Release();object=nullptr;
        if(empty.pstm){STATSTG stat={};CHECK(empty.pstm->Stat(&stat,STATFLAG_NONAME)==S_OK&&stat.cbSize.QuadPart==0);ReleaseStgMedium(&empty);}
    }
    if(object)object->Release();
}
static void source_operation_contract() {
    IDataObject *object=(IDataObject *)zenit_drag_data_create(0,"operation",9);CHECK(object!=nullptr);if(!object)return;
    CHECK(zenit_drag_data_drop_operation(object,1,7)==1);
    CHECK(zenit_drag_data_drop_operation(object,3,7)==0);
    CHECK(zenit_drag_data_drop_operation(object,2,1)==0);
    CLIPFORMAT logical=(CLIPFORMAT)RegisterClipboardFormatW(L"Logical Performed DropEffect");
    CLIPFORMAT performed=(CLIPFORMAT)RegisterClipboardFormatW(L"Performed DropEffect");
    auto set=[&](CLIPFORMAT format,DWORD value){
        STGMEDIUM medium={};medium.tymed=TYMED_HGLOBAL;medium.hGlobal=GlobalAlloc(GMEM_MOVEABLE,4);
        DWORD *p=(DWORD *)GlobalLock(medium.hGlobal);memcpy(p,&value,4);GlobalUnlock(medium.hGlobal);
        FORMATETC f={format,nullptr,DVASPECT_CONTENT,-1,TYMED_HGLOBAL};CHECK(object->SetData(&f,&medium,FALSE)==S_OK);ReleaseStgMedium(&medium);
    };
    set(performed,2);CHECK(zenit_drag_data_drop_operation(object,0,7)==2);
    set(logical,1);CHECK(zenit_drag_data_drop_operation(object,2,7)==1);
    set(performed,0);set(logical,2);CHECK(zenit_drag_data_drop_operation(object,0,7)==2);
    CHECK(zenit_drag_data_drop_operation(object,1,1)==1); // Disallowed notification cannot expand source policy.
    set(logical,0);CHECK(zenit_drag_data_drop_operation(object,1,7)==0);
    set(logical,3);CHECK(zenit_drag_data_drop_operation(object,1,7)==1);
    set(logical,8);CHECK(zenit_drag_data_drop_operation(object,1,7)==1);
    set(logical,0x80000002u);CHECK(zenit_drag_data_drop_operation(object,0,7)==2);
    set(logical,4);CHECK(zenit_drag_data_drop_operation(object,0,7)==4);
    object->Release();CHECK(zenit_drag_data_drop_operation(nullptr,1,7)==0);
}
static void preview_contract() {
    const unsigned char png[]={137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,2,0,0,0,2,8,6,0,0,0,114,182,13,36,0,0,0,23,73,68,65,84,120,156,99,56,145,98,212,192,37,34,247,159,1,4,52,2,42,28,0,44,250,4,74,75,130,15,60,0,0,0,0,73,69,78,68,174,66,96,130};
    HBITMAP bitmap=(HBITMAP)zenit_drag_preview_bitmap(png,sizeof(png),2,2);
    CHECK(bitmap!=nullptr);
    if(bitmap){DIBSECTION dib={};CHECK(GetObjectW(bitmap,sizeof(dib),&dib)==sizeof(dib));
        printf("Preview DIB: bitmap=%ldx%ld bits=%u header-height=%ld\n",dib.dsBm.bmWidth,dib.dsBm.bmHeight,dib.dsBm.bmBitsPixel,dib.dsBmih.biHeight);
        CHECK(dib.dsBm.bmWidth==2&&dib.dsBm.bmHeight==2&&dib.dsBm.bmBitsPixel==32);
        const BYTE expected[]={50,100,200,128,30,20,10,255,0,0,0,0,120,80,40,64};
        CHECK(dib.dsBm.bmBits&&memcmp(dib.dsBm.bmBits,expected,sizeof(expected))==0);
        // GetObject normalizes header height on this Windows build. Ask GDI
        // for top-down pixels to verify displayed orientation independently.
        HDC dc=CreateCompatibleDC(nullptr);BITMAPINFO info={};BYTE rendered[16]={};
        info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=2;info.bmiHeader.biHeight=-2;
        info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;info.bmiHeader.biCompression=BI_RGB;
        CHECK(dc&&GetDIBits(dc,bitmap,0,2,rendered,&info,DIB_RGB_COLORS)==2);
        for(unsigned i=0;i<4;++i)CHECK(memcmp(rendered+i*4,expected+i*4,3)==0);
        if(dc)DeleteDC(dc);
        CHECK(DeleteObject(bitmap));}
    bitmap=(HBITMAP)zenit_drag_preview_bitmap(png,sizeof(png),4,6);CHECK(bitmap!=nullptr);
    if(bitmap){DIBSECTION dib={};CHECK(GetObjectW(bitmap,sizeof(dib),&dib)==sizeof(dib));CHECK(dib.dsBm.bmWidth==4&&dib.dsBm.bmHeight==6);CHECK(DeleteObject(bitmap));}
    CHECK(zenit_drag_preview_bitmap(nullptr,sizeof(png),2,2)==nullptr);
    CHECK(zenit_drag_preview_bitmap(png,7,2,2)==nullptr);
    CHECK(zenit_drag_preview_bitmap(png,16*1024*1024+1,2,2)==nullptr);
    CHECK(zenit_drag_preview_bitmap(png,sizeof(png),0,2)==nullptr);
    CHECK(zenit_drag_preview_bitmap(png,sizeof(png),2,4097)==nullptr);
    unsigned char corrupt[sizeof(png)];memcpy(corrupt,png,sizeof(png));corrupt[0]=0;
    CHECK(zenit_drag_preview_bitmap(corrupt,sizeof(corrupt),2,2)==nullptr);
    CHECK(zenit_drag_preview_bitmap(png,33,2,2)==nullptr);
    // Warmed WIC must not retain any of the caller-owned GDI bitmaps.
    DWORD before=GetGuiResources(GetCurrentProcess(),GR_GDIOBJECTS);
    for(unsigned i=0;i<32;++i){bitmap=(HBITMAP)zenit_drag_preview_bitmap(png,sizeof(png),16,16);CHECK(bitmap!=nullptr);if(bitmap)CHECK(DeleteObject(bitmap));}
    CHECK(GetGuiResources(GetCurrentProcess(),GR_GDIOBJECTS)==before);
    IDataObject *data=(IDataObject *)zenit_drag_data_create(0,"preview",7);
    IDragSourceHelper *helper=nullptr;
    CHECK(SUCCEEDED(CoCreateInstance(CLSID_DragDropHelper,nullptr,CLSCTX_INPROC_SERVER,IID_IDragSourceHelper,(void **)&helper)));
    if(helper&&data){
        bitmap=(HBITMAP)zenit_drag_preview_bitmap(png,sizeof(png),32,16);
        SHDRAGIMAGE image={{32,16},{4,4},bitmap,CLR_NONE};
        HRESULT result=helper->InitializeFromBitmap(&image,data);
        printf("Shell preview initialization: 0x%08lx\n",(unsigned long)result);
        CHECK(SUCCEEDED(result));if(FAILED(result)&&bitmap)DeleteObject(bitmap);
    }
    if(helper)helper->Release();if(data)data->Release();
    before=GetGuiResources(GetCurrentProcess(),GR_GDIOBJECTS);
    for(unsigned i=0;i<8;++i){
        data=(IDataObject *)zenit_drag_data_create(0,"preview",7);helper=nullptr;
        HRESULT created=CoCreateInstance(CLSID_DragDropHelper,nullptr,CLSCTX_INPROC_SERVER,IID_IDragSourceHelper,(void **)&helper);
        CHECK(SUCCEEDED(created)&&data&&helper);
        if(helper&&data){bitmap=(HBITMAP)zenit_drag_preview_bitmap(png,sizeof(png),32,16);SHDRAGIMAGE image={{32,16},{4,4},bitmap,CLR_NONE};
            HRESULT result=helper->InitializeFromBitmap(&image,data);CHECK(SUCCEEDED(result));if(FAILED(result)&&bitmap)DeleteObject(bitmap);}
        if(helper)helper->Release();if(data)data->Release();
    }
    CHECK(GetGuiResources(GetCurrentProcess(),GR_GDIOBJECTS)==before);
}
int main(int argc,char **argv){
    if(argc==2 && !freopen(argv[1],"w",stdout))return 2;
    setvbuf(stdout, nullptr, _IONBF, 0);
    HWND foreground=GetForegroundWindow();
    CHECK(SUCCEEDED(OleInitialize(nullptr)));
    const wchar_t unicode[]=L"中文 \U0001f9ea\nline";
    verify(CF_UNICODETEXT,2,unicode,sizeof(unicode),true,"中文 🧪\nline");
    const wchar_t missing[]={L'a',L'b'};verify(CF_UNICODETEXT,2,missing,sizeof(missing),false);
    const wchar_t surrogate[]={0xd800,0};verify(CF_UNICODETEXT,2,surrogate,sizeof(surrogate),false);
    const unsigned char odd[]={0x61,0,0};verify(CF_UNICODETEXT,2,odd,sizeof(odd),false);
    struct WideDrop {DROPFILES header;wchar_t names[128];} drop={};drop.header.pFiles=sizeof(DROPFILES);drop.header.fWide=TRUE;
    const wchar_t paths[]=L"C:\\输入-\U0001f9ea.txt\0D:\\another.txt\0";memcpy(drop.names,paths,sizeof(paths));
    verify(CF_HDROP,1,&drop,sizeof(DROPFILES)+sizeof(paths),true,"C:\\输入-🧪.txt\nD:\\another.txt");
    drop.header.pFiles=2;verify(CF_HDROP,1,&drop,sizeof(drop),false);
    drop.header.pFiles=sizeof(drop)+4;verify(CF_HDROP,1,&drop,sizeof(drop),false);
    drop.header.pFiles=sizeof(DROPFILES)+1;verify(CF_HDROP,1,&drop,sizeof(drop),false);
    drop.header.pFiles=sizeof(DROPFILES);
    verify(CF_HDROP,1,&drop,sizeof(DROPFILES)+sizeof(paths)-2,false);
    drop.names[1]=L'\n';verify(CF_HDROP,1,&drop,sizeof(drop),false);
    struct AnsiDrop {DROPFILES header;char names[32];} ansi={};ansi.header.pFiles=sizeof(DROPFILES);memcpy(ansi.names,"C:\\a.txt\0D:\\b.txt\0",19);
    verify(CF_HDROP,1,&ansi,sizeof(ansi),true,"C:\\a.txt\nD:\\b.txt");
    CLIPFORMAT internal=(CLIPFORMAT)RegisterClipboardFormatW(L"Zenit.Internal.UTF8.v1");
    unsigned char bytes[]={5,0,0,0,'A',0,0xe4,0xb8,0xad,0xcc,0xcc};
    Data d(internal,bytes,sizeof(bytes));Bytes b;CHECK(read_data(&d,internal,3,b));CHECK(b.size==5&&memcmp(b.data,bytes+4,5)==0);
    bytes[0]=20;verify(internal,3,bytes,sizeof(bytes),false);
    bytes[0]=5;bytes[6]=0xff;verify(internal,3,bytes,sizeof(bytes),false);
    bytes[0]=0;verify(internal,3,bytes,sizeof(bytes),true,"");
    uint32_t over=payload_cap+1;memcpy(bytes,&over,4);verify(internal,3,bytes,sizeof(bytes),false,nullptr,true);
    wchar_t *big=(wchar_t *)malloc((payload_cap+2)*2);for(size_t i=0;i<payload_cap+1;++i)big[i]=L'x';big[payload_cap+1]=0;
    verify(CF_UNICODETEXT,2,big,(payload_cap+2)*2,false,nullptr,true);free(big);
    HWND window=CreateWindowExW(0,L"STATIC",L"owned hidden drop contract",WS_OVERLAPPED,0,0,200,200,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
    CHECK(window!=nullptr);
    {
        uint64_t sequence=0;Target target(window,serial,&sequence);Data text(CF_UNICODETEXT,unicode,sizeof(unicode));
        DWORD effect=7;POINTL point={50,50};ZenitDragPacket packet={};
        CHECK(target.DragEnter(&text,0,point,&effect)==S_OK&&effect==1);
        CHECK(target.peek(&packet)&&packet.kind==0&&packet.serial==1);
        CHECK(!target.consume(2)&&target.consume(1));
        for(unsigned i=0;i<1000;++i){effect=7;target.DragOver(0,point,&effect);}
        CHECK(target.peek(&packet)&&packet.kind==1&&packet.serial==1001);
        CHECK(target.consume(packet.serial)&&!target.peek(&packet));
        effect=7;CHECK(target.Drop(&text,0,point,&effect)==S_OK&&effect==1);
        CHECK(target.peek(&packet)&&packet.kind==3&&packet.operation==1&&packet.payload_kind==2);
        CHECK(packet.length==strlen("中文 🧪\nline")&&memcmp(packet.bytes,"中文 🧪\nline",packet.length)==0);
        CHECK(!target.consume(packet.serial+1)&&target.consume(packet.serial));
        CHECK(!target.set(8)&&target.set(2));effect=7;target.DragEnter(&text,MK_CONTROL,point,&effect);CHECK(effect==0);target.DragLeave();
        while(target.peek(&packet))target.consume(packet.serial);
        target.set(4);effect=7;target.DragEnter(&text,MK_CONTROL|MK_SHIFT,point,&effect);CHECK(effect==4);target.DragLeave();
        while(target.peek(&packet))target.consume(packet.serial);
        target.set(1);
        unsigned enters=0,exits=0,accepted=0;
        for(unsigned i=0;i<100;++i){effect=7;target.DragEnter(&text,0,point,&effect);if(effect)++accepted;target.DragLeave();}
        while(target.peek(&packet)){if(packet.kind==0)++enters;if(packet.kind==2)++exits;target.consume(packet.serial);}
        CHECK(accepted==63&&enters==accepted&&exits==accepted);
        wchar_t *full=(wchar_t *)malloc((payload_cap+1)*2);CHECK(full!=nullptr);
        for(size_t i=0;i<payload_cap;++i)full[i]=L'x';full[payload_cap]=0;
        Data large(CF_UNICODETEXT,full,(payload_cap+1)*2);
        for(unsigned i=0;i<5;++i){effect=7;target.DragEnter(&large,0,point,&effect);effect=7;target.Drop(&large,0,point,&effect);CHECK(effect==(i<4?1u:0u));}
        unsigned dropped=0,rejected=0;
        while(target.peek(&packet)){if(packet.kind==3){++dropped;CHECK(packet.length==payload_cap);}if(packet.kind==2)++rejected;target.consume(packet.serial);}
        CHECK(dropped==4&&rejected==1);free(full);
        uint64_t before=sequence;CHECK(target.detach()==window);
        effect=7;target.DragEnter(&text,0,point,&effect);CHECK(effect==0&&!target.peek(&packet)&&sequence==before);
        effect=7;target.Drop(&text,0,point,&effect);CHECK(effect==0&&sequence==before);
    }
    a11y_provider_contract(window);
    a11y_focus_contract(window);
    a11y_invoke_contract(window);
    a11y_toggle_contract(window);
    a11y_value_contract(window);
    a11y_range_contract(window);
    a11y_selection_contract(window);
    a11y_multi_selection_contract(window);
    a11y_expansion_contract(window);
    a11y_text_range_contract(window);
    a11y_text_read_view_contract(window);
    a11y_visible_ranges_contract(window);
    a11y_point_range_contract(window);
    a11y_text_pattern_contract(window);
    a11y_text_search_contract(window);
    a11y_character_contract(window);
    a11y_text_move_contract(window);
    a11y_text_selection_operations_contract(window);
    a11y_logical_units_contract(window);
    a11y_line_units_contract(window);
    a11y_unit_resolution_contract(window);
    a11y_scroll_contract(window);
    a11y_bounding_rectangles_contract(window);
    DestroyWindow(window);CHECK(GetForegroundWindow()==foreground);
    source_contract();
    source_operation_contract();
    preview_contract();CHECK(GetForegroundWindow()==foreground);
    a11y_snapshot_contract(); CHECK(GetForegroundWindow()==foreground);
    a11y_geometry_contract(); CHECK(GetForegroundWindow()==foreground);
    a11y_caret_contract(); CHECK(GetForegroundWindow()==foreground);
    a11y_rows_contract(); CHECK(GetForegroundWindow()==foreground);
    OleUninitialize();printf("Windows native contracts: %u/%u checks passed\n",checks-failed,checks);return failed?1:0;
}
