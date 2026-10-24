#include <windows.h>
#include <wincodec.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
// Backend capture bytes are straight RGBA. Preserve alpha and padded row stride.
extern "C" int zenit_d12_write_png_rgba(const char *path,const uint8_t *rgba,size_t length,
    uint32_t width,uint32_t height,uint32_t stride) {
    if (!path || !rgba || !width || !height || width>UINT32_MAX/4 || stride<width*4 ||
        (uint64_t)stride*height>length || (uint64_t)stride*height>UINT32_MAX) return 1;
    int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,nullptr,0);
    if (!count) return 1;
    auto wide=(wchar_t *)calloc((size_t)count,sizeof(wchar_t)); if (!wide) return 2;
    if (!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,wide,count)) { free(wide); return 1; }
    HRESULT apartment=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    if (FAILED(apartment) && apartment!=RPC_E_CHANGED_MODE) { free(wide); return 2; }
    IWICImagingFactory *factory=nullptr; IWICStream *stream=nullptr;
    IWICBitmapEncoder *encoder=nullptr; IWICBitmapFrameEncode *frame=nullptr;
    HRESULT hr=CoCreateInstance(CLSID_WICImagingFactory,nullptr,CLSCTX_INPROC_SERVER,
        IID_IWICImagingFactory,(void **)&factory);
    if (SUCCEEDED(hr)) hr=factory->CreateStream(&stream);
    if (SUCCEEDED(hr)) hr=stream->InitializeFromFilename(wide,GENERIC_WRITE);
    if (SUCCEEDED(hr)) hr=factory->CreateEncoder(GUID_ContainerFormatPng,nullptr,&encoder);
    if (SUCCEEDED(hr)) hr=encoder->Initialize(stream,WICBitmapEncoderNoCache);
    if (SUCCEEDED(hr)) hr=encoder->CreateNewFrame(&frame,nullptr);
    if (SUCCEEDED(hr)) hr=frame->Initialize(nullptr);
    if (SUCCEEDED(hr)) hr=frame->SetSize(width,height);
    WICPixelFormatGUID format=GUID_WICPixelFormat32bppBGRA;
    if (SUCCEEDED(hr)) hr=frame->SetPixelFormat(&format);
    if (SUCCEEDED(hr) && !IsEqualGUID(format,GUID_WICPixelFormat32bppBGRA)) hr=E_FAIL;
    // WIC's native PNG encoder negotiates BGRA. Swap channels explicitly;
    // padding bytes never become pixels and alpha remains straight.
    auto row=SUCCEEDED(hr)?(BYTE *)malloc((size_t)width*4):nullptr;
    if (SUCCEEDED(hr) && !row) hr=E_OUTOFMEMORY;
    for (uint32_t y=0;SUCCEEDED(hr) && y<height;++y) {
        const auto source=rgba+(size_t)y*stride;
        for (uint32_t x=0;x<width;++x) {
            row[x*4]=source[x*4+2]; row[x*4+1]=source[x*4+1];
            row[x*4+2]=source[x*4]; row[x*4+3]=source[x*4+3];
        }
        hr=frame->WritePixels(1,width*4,width*4,row);
    }
    free(row);
    if (SUCCEEDED(hr)) hr=frame->Commit();
    if (SUCCEEDED(hr)) hr=encoder->Commit();
    if (frame) frame->Release(); if (encoder) encoder->Release();
    if (stream) stream->Release(); if (factory) factory->Release();
    if (SUCCEEDED(apartment)) CoUninitialize(); free(wide);
#ifdef ZENIT_D12_TEST
    if (FAILED(hr)) fprintf(stderr,"WIC PNG encode failed HRESULT=%08lx\n",(unsigned long)hr);
#endif
    return SUCCEEDED(hr)?0:2;
}
