// Test-only native diagnostics and GPU gate; all copies use the production Queue.
#include "d3d12_resources.h"
#include <windows.h>
#include <wincodec.h>
extern "C" int zenit_d12_test_decode_png(const char *path,unsigned char *pixels) {
    wchar_t wide[32768];
    if (!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,wide,32768)) return 1;
    HRESULT apartment=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    if (FAILED(apartment) && apartment!=RPC_E_CHANGED_MODE) return 1;
    IWICImagingFactory *factory=nullptr; IWICBitmapDecoder *decoder=nullptr;
    IWICBitmapFrameDecode *frame=nullptr; IWICFormatConverter *converter=nullptr;
    HRESULT hr=CoCreateInstance(CLSID_WICImagingFactory,nullptr,CLSCTX_INPROC_SERVER,
        IID_IWICImagingFactory,(void **)&factory);
    if (SUCCEEDED(hr)) hr=factory->CreateDecoderFromFilename(wide,nullptr,GENERIC_READ,WICDecodeMetadataCacheOnLoad,&decoder);
    if (SUCCEEDED(hr)) hr=decoder->GetFrame(0,&frame);
    UINT w=0,h=0;
    if (SUCCEEDED(hr)) hr=frame->GetSize(&w,&h);
    if (SUCCEEDED(hr) && (w!=2 || h!=2)) hr=E_FAIL;
    if (SUCCEEDED(hr)) hr=factory->CreateFormatConverter(&converter);
    if (SUCCEEDED(hr)) hr=converter->Initialize(frame,GUID_WICPixelFormat32bppRGBA,
        WICBitmapDitherTypeNone,nullptr,0,WICBitmapPaletteTypeCustom);
    if (SUCCEEDED(hr)) hr=converter->CopyPixels(nullptr,8,16,pixels);
    if (converter) converter->Release(); if (frame) frame->Release();
    if (decoder) decoder->Release(); if (factory) factory->Release();
    if (SUCCEEDED(apartment)) CoUninitialize();
    return SUCCEEDED(hr)?0:1;
}
extern "C" void *zenit_d12_test_hidden_window_create() {
    return CreateWindowExW(WS_EX_NOACTIVATE,L"STATIC",L"Zenit D3D12 background surface",
        WS_OVERLAPPEDWINDOW,0,0,64,64,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
}
extern "C" void zenit_d12_test_hidden_window_destroy(void *window) { DestroyWindow((HWND)window); }
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <stdio.h>
#include <stdlib.h>
static void check(HRESULT result, const char *stage) {
    if (FAILED(result)) { fprintf(stderr, "%s failed HRESULT=%08lx\n", stage, (unsigned long)result); ExitProcess(2); }
}
extern "C" uint64_t zenit_d12_test_width(ZenitD12Buffer *buffer) {
    return ((ID3D12Resource *)zenit_d12_buffer_native(buffer))->GetDesc().Width;
}

// Hold the GPU queue before its copies, producing deterministic timeout tests.
// Test owns the gate until the submitted fence has completed.
struct TestGate { ID3D12Fence *fence; ID3D12CommandQueue *queue; };
extern "C" void *zenit_d12_test_gate_create(ZenitD12Device *owner, ZenitD12Queue *queue) {
    auto gate = (TestGate *)calloc(1, sizeof(TestGate));
    if (!gate) ExitProcess(5);
    auto device = (ID3D12Device *)zenit_d12_device_native(owner);
    check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_ID3D12Fence, (void **)&gate->fence), "gate create");
    gate->queue = (ID3D12CommandQueue *)zenit_d12_queue_native(queue);
    gate->queue->AddRef();
    check(gate->queue->Wait(gate->fence, 1), "gate wait");
    return gate;
}
extern "C" void zenit_d12_test_gate_signal(void *opaque) {
    check(((TestGate *)opaque)->fence->Signal(1), "gate signal");
}
extern "C" void zenit_d12_test_gate_release(void *opaque) {
    auto gate = (TestGate *)opaque;
    // Even an assertion failure before a post-gate submission must drain the
    // queued GPU Wait before dropping the gate's fence reference.
    check(gate->queue->Signal(gate->fence, 2), "gate drain signal");
    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!event) ExitProcess(3);
    check(gate->fence->SetEventOnCompletion(2, event), "gate drain completion");
    if (WaitForSingleObject(event, 5000) != WAIT_OBJECT_0 || gate->fence->GetCompletedValue() == UINT64_MAX) ExitProcess(4);
    CloseHandle(event); gate->fence->Release(); gate->queue->Release(); free(gate);
}

extern "C" void zenit_d12_test_debug_enable() {
    ID3D12Debug *debug = nullptr;
    HRESULT hr = D3D12GetDebugInterface(IID_ID3D12Debug, (void **)&debug);
    if (FAILED(hr)) {
        fprintf(stderr, "D3D12 debug layer unavailable HRESULT=%08lx (validation not claimed)\n", (unsigned long)hr);
        if (getenv("ZENIT_D3D12_REQUIRE_VALIDATION")) ExitProcess(7);
        return;
    }
    debug->EnableDebugLayer();
    if (getenv("ZENIT_D3D12_GBV")) {
        ID3D12Debug1 *validation = nullptr;
        hr = debug->QueryInterface(IID_ID3D12Debug1, (void **)&validation);
        if (SUCCEEDED(hr)) {
            validation->SetEnableGPUBasedValidation(TRUE); validation->Release();
            fprintf(stderr, "D3D12 GPU-based validation enabled\n");
        } else {
            fprintf(stderr, "D3D12 GPU-based validation unavailable HRESULT=%08lx\n", (unsigned long)hr);
            if (getenv("ZENIT_D3D12_REQUIRE_VALIDATION")) ExitProcess(7);
        }
    }
    debug->Release();
    fprintf(stderr, "D3D12 debug layer enabled\n");
}
extern "C" void zenit_d12_test_debug_check(ZenitD12Device *owner) {
    ID3D12InfoQueue *info = nullptr;
    HRESULT hr = ((ID3D12Device *)zenit_d12_device_native(owner))->QueryInterface(IID_ID3D12InfoQueue, (void **)&info);
    if (FAILED(hr)) return; // Setup already reports missing validation support.
    UINT64 count = info->GetNumStoredMessagesAllowedByRetrievalFilter();
    unsigned errors = 0;
    for (UINT64 i = 0; i < count; ++i) {
        SIZE_T size = 0;
        check(info->GetMessage(i, nullptr, &size), "debug message size");
        auto message = (D3D12_MESSAGE *)malloc(size);
        if (!message) ExitProcess(5);
        check(info->GetMessage(i, message, &size), "debug message");
        if (message->Severity == D3D12_MESSAGE_SEVERITY_WARNING)
            fprintf(stderr, "D3D12 validation warning id=%u: %s\n", unsigned(message->ID), message->pDescription);
        if (message->Severity == D3D12_MESSAGE_SEVERITY_ERROR || message->Severity == D3D12_MESSAGE_SEVERITY_CORRUPTION) {
            fprintf(stderr, "D3D12 validation error: %s\n", message->pDescription); ++errors;
        }
        free(message);
    }
    info->Release();
    fprintf(stderr, "D3D12 validation messages=%llu errors=%u\n", (unsigned long long)count, errors);
    if (errors) ExitProcess(6);
    fprintf(stderr, "PASS: D3D12 debug layer found no errors/corruption\n");
}
