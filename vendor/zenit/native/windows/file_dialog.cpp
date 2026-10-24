#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shobjidl.h>
#include <stdlib.h>
#include <limits.h>

// Caller owns the UTF-8 output buffer. Zero means cancellation; negative
// results distinguish native failure, insufficient buffer and invalid state.
extern "C" int zenit_win_file_dialog(void *owner, unsigned kind,
    const wchar_t *title, const wchar_t *directory, char *out, size_t capacity) {
    if (!capacity || capacity>INT_MAX) return -2;
    out[0]=0;
    HWND hwnd=(HWND)owner;
    if (!IsWindow(hwnd) || kind>2) return -4;
    if (GetWindowThreadProcessId(hwnd,nullptr)!=GetCurrentThreadId()) return -3;
    const char *background=getenv("ZENIT_E2E_BACKGROUND");
    if (background && !strcmp(background,"1")) return -4;
    HRESULT initialized=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED|COINIT_DISABLE_OLE1DDE);
    if (FAILED(initialized)) return initialized==RPC_E_CHANGED_MODE ? -3 : -1;
    IFileDialog *dialog=nullptr;
    IShellItem *folder=nullptr,*result=nullptr;
    PWSTR path=nullptr;
    int answer=-1;
    HRESULT hr=CoCreateInstance(kind==1 ? CLSID_FileSaveDialog : CLSID_FileOpenDialog,
        nullptr,CLSCTX_INPROC_SERVER,IID_IFileDialog,(void **)&dialog);
    if (SUCCEEDED(hr)) {
        FILEOPENDIALOGOPTIONS options;
        hr=dialog->GetOptions(&options);
        if (SUCCEEDED(hr)) hr=dialog->SetOptions(options|FOS_FORCEFILESYSTEM|FOS_NOCHANGEDIR|
            (kind==2 ? FOS_PICKFOLDERS : 0));
        // The shared SDK uses title as the suggested filename for Save As.
        if (SUCCEEDED(hr) && title && *title) hr=kind==1 ? dialog->SetFileName(title) : dialog->SetTitle(title);
        // The starting folder is a hint, as on macOS: one that cannot be
        // resolved leaves the dialog at its default location.
        if (SUCCEEDED(hr) && directory && *directory &&
                SUCCEEDED(SHCreateItemFromParsingName(directory,nullptr,IID_IShellItem,(void **)&folder)))
            dialog->SetFolder(folder);
        if (SUCCEEDED(hr)) hr=dialog->Show(hwnd);
        if (hr==HRESULT_FROM_WIN32(ERROR_CANCELLED)) answer=0;
        else if (SUCCEEDED(hr)) {
            hr=dialog->GetResult(&result);
            if (SUCCEEDED(hr)) hr=result->GetDisplayName(SIGDN_FILESYSPATH,&path);
            if (SUCCEEDED(hr)) {
                int bytes=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,path,-1,nullptr,0,nullptr,nullptr);
                if (bytes>0 && (size_t)bytes>capacity) answer=-2;
                else if (bytes>0 && WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,path,-1,out,(int)capacity,nullptr,nullptr)==bytes) answer=bytes-1;
            }
        }
    }
    if (path) CoTaskMemFree(path);
    if (result) result->Release();
    if (folder) folder->Release();
    if (dialog) dialog->Release();
    CoUninitialize();
    return answer;
}
