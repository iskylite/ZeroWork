// Dedicated OLE STA keeps the App's render / SDK / test RPC pump responsive.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <ole2.h>
#include <shlobj.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "drag_data.h"
#include "drag_source.h"
#ifndef ZENIT_PLACEMENT_NEW
#define ZENIT_PLACEMENT_NEW
inline void *operator new(size_t,void *storage) noexcept {return storage;}
#endif
alignas(8) static LONG64 source_sequence=0;
class SourceSession final: public IDropSource {
    LONG refs=1;
public:
    HWND owner=nullptr;
    DWORD owner_thread=0;
    LONG cancelled=0,done=0;
    unsigned kind=0,operations=0,effect=0;
    uint64_t token=0;
    char *bytes=nullptr;size_t length=0;
    HBITMAP preview=nullptr;
    SIZE preview_size={};POINT hotspot={};
    ~SourceSession(){free(bytes);if(preview)DeleteObject(preview);}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void **out) override {
        if(!out)return E_POINTER;*out=nullptr;
        if(iid==IID_IUnknown||iid==IID_IDropSource){*out=(IDropSource *)this;AddRef();return S_OK;}return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override{return InterlockedIncrement(&refs);}
    ULONG STDMETHODCALLTYPE Release() override{ULONG n=InterlockedDecrement(&refs);if(!n){this->~SourceSession();free(this);}return n;}
    HRESULT STDMETHODCALLTYPE QueryContinueDrag(BOOL escape,DWORD) override {
        if(escape||InterlockedCompareExchange(&cancelled,0,0)||GetForegroundWindow()!=owner)return DRAGDROP_S_CANCEL;
        // AttachThreadInput resets GetKeyState; inspect physical button state.
        return (GetAsyncKeyState(VK_LBUTTON)&0x8000)?S_OK:DRAGDROP_S_DROP;
    }
    HRESULT STDMETHODCALLTYPE GiveFeedback(DWORD) override{return DRAGDROP_S_USEDEFAULTCURSORS;}
};
static void CALLBACK source_cancel_tick(HWND timer,UINT,UINT_PTR,DWORD) {
    SourceSession *session=(SourceSession *)GetWindowLongPtrW(timer,GWLP_USERDATA);
    if(!session||!InterlockedCompareExchange(&session->cancelled,0,0))return;
    HWND capture=GetCapture();
    // Wake only this STA's own OLE capture window. No injected mouse release,
    // no message sent to an old thread ID or an application window.
    if(capture&&GetWindowThreadProcessId(capture,nullptr)==GetCurrentThreadId()) {
        POINT point={};GetCursorPos(&point);ScreenToClient(capture,&point);
        PostMessageW(capture,WM_MOUSEMOVE,MK_LBUTTON,MAKELPARAM(point.x,point.y));
        PostMessageW(capture,WM_KEYDOWN,VK_ESCAPE,1);
        PostMessageW(capture,WM_KEYUP,VK_ESCAPE,(LPARAM)0xc0000001u);
    }
}
static DWORD WINAPI source_worker(void *context) {
    SourceSession *session=(SourceSession *)context;
    HRESULT ole=OleInitialize(nullptr);bool attached=false;
    HWND timer=nullptr;IDataObject *data=nullptr;IDragSourceHelper *helper=nullptr;
    if(SUCCEEDED(ole)) {
        timer=CreateWindowExW(0,L"STATIC",L"Zenit source cancellation",0,0,0,0,0,HWND_MESSAGE,nullptr,GetModuleHandleW(nullptr),nullptr);
        if(timer){SetWindowLongPtrW(timer,GWLP_USERDATA,(LONG_PTR)session);if(!SetTimer(timer,1,20,source_cancel_tick)){DestroyWindow(timer);timer=nullptr;}}
        data=(IDataObject *)zenit_drag_data_create(session->kind,session->bytes,session->length);
        bool valid=timer&&data&&!InterlockedCompareExchange(&session->cancelled,0,0);
        if(valid&&session->preview) {
            HRESULT preview_result=CoCreateInstance(CLSID_DragDropHelper,nullptr,CLSCTX_INPROC_SERVER,IID_IDragSourceHelper,(void **)&helper);
            valid=SUCCEEDED(preview_result);
            if(valid){SHDRAGIMAGE image={session->preview_size,session->hotspot,session->preview,CLR_NONE};
                preview_result=helper->InitializeFromBitmap(&image,data);valid=SUCCEEDED(preview_result);
                // Shell owns the bitmap following successful initialization.
                if(valid)session->preview=nullptr;}
            if(!valid)fprintf(stderr,"[windows-source-preview] token=%llu hr=0x%08lx\n",(unsigned long long)session->token,(unsigned long)preview_result);
        }
        if(valid) {
            attached=AttachThreadInput(GetCurrentThreadId(),session->owner_thread,TRUE)!=FALSE;
            if(attached&&!InterlockedCompareExchange(&session->cancelled,0,0)) {
                DWORD effect=0;HRESULT result=DoDragDrop(data,session,session->operations,&effect);
                session->effect=result==DRAGDROP_S_DROP?zenit_drag_data_drop_operation(data,effect,session->operations):0;
            }
        }
        if(attached)AttachThreadInput(GetCurrentThreadId(),session->owner_thread,FALSE);
        if(helper)helper->Release();if(data)data->Release();
        if(timer){KillTimer(timer,1);SetWindowLongPtrW(timer,GWLP_USERDATA,0);DestroyWindow(timer);}
        OleUninitialize();
    }
    InterlockedExchange(&session->done,1);session->Release();return 0;
}
extern "C" void *zenit_drag_source_start(void *window,unsigned kind,const char *bytes,size_t length,unsigned operations,
    const unsigned char *png,size_t png_length,float width,float height,float hotspot_x,float hotspot_y,uint64_t *token,int *error) {
    if(token)*token=0;if(error)*error=-1;
    HWND hwnd=(HWND)window;DWORD pid=0,thread=hwnd?GetWindowThreadProcessId(hwnd,&pid):0;
    char background[8]={};GetEnvironmentVariableA("ZENIT_E2E_BACKGROUND",background,sizeof(background));
    POINT cursor={};RECT client={};
    if(!token||!hwnd||!IsWindow(hwnd)||pid!=GetCurrentProcessId()||thread!=GetCurrentThreadId()||background[0]=='1'||
       GetForegroundWindow()!=hwnd||!(GetAsyncKeyState(VK_LBUTTON)&0x8000)||!operations||(operations&~7u)||
       !GetCursorPos(&cursor)||!ScreenToClient(hwnd,&cursor)||!GetClientRect(hwnd,&client)||!PtInRect(&client,cursor)||
       !isfinite(width)||!isfinite(height)||!isfinite(hotspot_x)||!isfinite(hotspot_y)||width<=0||height<=0||width>4096||height>4096||
       hotspot_x<0||hotspot_y<0||hotspot_x>width||hotspot_y>height||(!png&&png_length))return nullptr;
    IDataObject *validation=(IDataObject *)zenit_drag_data_create(kind,bytes,length);if(!validation)return nullptr;validation->Release();
    void *storage=malloc(sizeof(SourceSession));if(!storage){if(error)*error=-2;return nullptr;}
    SourceSession *session=new(storage)SourceSession;
    session->bytes=(char *)malloc(length);if(!session->bytes){session->Release();if(error)*error=-2;return nullptr;}
    memcpy(session->bytes,bytes,length);session->length=length;session->kind=kind;session->operations=operations;
    session->owner=hwnd;session->owner_thread=thread;
    if(png_length) {
        float scale=(float)GetDpiForWindow(hwnd)/96.0f;
        unsigned w=(unsigned)ceilf(width*scale),h=(unsigned)ceilf(height*scale);
        session->preview=(HBITMAP)zenit_drag_preview_bitmap(png,png_length,w,h);
        if(!session->preview){session->Release();return nullptr;}
        session->preview_size={(LONG)w,(LONG)h};session->hotspot={(LONG)roundf(hotspot_x*scale),(LONG)roundf(hotspot_y*scale)};
    }
    session->token=(uint64_t)InterlockedIncrement64(&source_sequence);
    if(!session->token)session->token=(uint64_t)InterlockedIncrement64(&source_sequence);
    if(GetCapture()==hwnd)ReleaseCapture();
    session->AddRef();HANDLE worker=CreateThread(nullptr,0,source_worker,session,0,nullptr);
    if(!worker){session->Release();session->Release();if(error)*error=-3;return nullptr;}
    CloseHandle(worker);*token=session->token;if(error)*error=0;return session;
}
extern "C" int zenit_drag_source_result(void *context,unsigned *operation,uint64_t *token) {
    SourceSession *session=(SourceSession *)context;
    if(!session||!operation||!token||!InterlockedCompareExchange(&session->done,0,0))return 0;
    *operation=session->effect;*token=session->token;return 1;
}
extern "C" void zenit_drag_source_cancel(void *context){if(context)InterlockedExchange(&((SourceSession *)context)->cancelled,1);}
extern "C" void zenit_drag_source_release(void *context){if(context)((SourceSession *)context)->Release();}
