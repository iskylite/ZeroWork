/* Included by window_bridge.c: native PNG / DIB / bitmap clipboard support. */
#include <objbase.h>
#include <initguid.h>
#include <wincodec.h>

#define CLIP_ENCODED_LIMIT (64u*1024u*1024u)
#define CLIP_PIXEL_LIMIT (256u*1024u*1024u)
typedef struct ZenitClipboardImage {
    uint32_t width, height;
    unsigned char *rgba, *raw;
    size_t raw_len;
} ZenitClipboardImage;

void zenit_win_clipboard_free_image(ZenitClipboardImage *image) {
    free(image->rgba); free(image->raw); memset(image,0,sizeof(*image));
}

static unsigned char *copy_clip_global(UINT format, size_t *length) {
    HGLOBAL memory = GetClipboardData(format);
    if (!memory) return NULL;
    SIZE_T size = GlobalSize(memory);
    if (!size || size>CLIP_ENCODED_LIMIT) return NULL;
    const void *source = GlobalLock(memory);
    if (!source) return NULL;
    unsigned char *copy = malloc(size);
    if (copy) { memcpy(copy,source,size); *length=size; }
    GlobalUnlock(memory);
    return copy;
}

static int wic_pixels(IWICImagingFactory *factory, IWICBitmapSource *source, ZenitClipboardImage *out) {
    UINT width=0,height=0;
    HRESULT hr = IWICBitmapSource_GetSize(source,&width,&height);
    uint64_t bytes = (uint64_t)width*height*4;
    if (FAILED(hr) || !width || !height || width>16384 || height>16384 || bytes>CLIP_PIXEL_LIMIT) return 0;
    IWICFormatConverter *converter = NULL;
    hr = IWICImagingFactory_CreateFormatConverter(factory,&converter);
    if (FAILED(hr)) return 0;
    hr = IWICFormatConverter_Initialize(converter,source,&GUID_WICPixelFormat32bppRGBA,
        WICBitmapDitherTypeNone,NULL,0,WICBitmapPaletteTypeCustom);
    unsigned char *pixels = NULL;
    if (SUCCEEDED(hr)) {
        pixels = malloc((size_t)bytes);
        if (!pixels) hr=E_OUTOFMEMORY;
        else hr=IWICFormatConverter_CopyPixels(converter,NULL,width*4,(UINT)bytes,pixels);
    }
    IWICFormatConverter_Release(converter);
    if (FAILED(hr)) { free(pixels); return 0; }
    out->width=width; out->height=height; out->rgba=pixels;
    return 1;
}

static int wic_decode(IWICImagingFactory *factory, unsigned char *bytes, size_t length, ZenitClipboardImage *out) {
    if (!bytes || !length || length>CLIP_ENCODED_LIMIT) return 0;
    IWICStream *stream=NULL;
    IWICBitmapDecoder *decoder=NULL;
    IWICBitmapFrameDecode *frame=NULL;
    HRESULT hr=IWICImagingFactory_CreateStream(factory,&stream);
    if (SUCCEEDED(hr)) hr=IWICStream_InitializeFromMemory(stream,bytes,(DWORD)length);
    if (SUCCEEDED(hr)) hr=IWICImagingFactory_CreateDecoderFromStream(factory,(IStream *)stream,NULL,WICDecodeMetadataCacheOnLoad,&decoder);
    if (SUCCEEDED(hr)) hr=IWICBitmapDecoder_GetFrame(decoder,0,&frame);
    int ok=SUCCEEDED(hr) && wic_pixels(factory,(IWICBitmapSource *)frame,out);
    if (frame) IWICBitmapFrameDecode_Release(frame);
    if (decoder) IWICBitmapDecoder_Release(decoder);
    if (stream) IWICStream_Release(stream);
    return ok;
}

/* Windows DIBs omit the 14-byte BMP file header. Compute the pixel offset
   without trusting external palette/header sizes, then let WIC validate pixels. */
static int wic_dib(IWICImagingFactory *factory, const unsigned char *dib, size_t length, ZenitClipboardImage *out) {
    if (!dib || length<sizeof(BITMAPINFOHEADER) || length>CLIP_ENCODED_LIMIT-sizeof(BITMAPFILEHEADER)) return 0;
    BITMAPINFOHEADER header; memcpy(&header,dib,sizeof(header));
    if (header.biSize<sizeof(header) || header.biSize>length || header.biBitCount>32 || !header.biBitCount) return 0;
    uint64_t offset=header.biSize;
    if (header.biSize==sizeof(header) && header.biCompression==BI_BITFIELDS) offset+=12;
    if (header.biSize==sizeof(header) && header.biCompression==6) offset+=16; /* BI_ALPHABITFIELDS */
    uint64_t colors=header.biClrUsed;
    if (!colors && header.biBitCount<=8) colors=1u<<header.biBitCount;
    offset+=colors*sizeof(RGBQUAD);
    if (offset>=length) return 0;
    size_t size=length+sizeof(BITMAPFILEHEADER);
    unsigned char *bmp=malloc(size);
    if (!bmp) return 0;
    BITMAPFILEHEADER file={0}; file.bfType=0x4d42; file.bfSize=(DWORD)size;
    file.bfOffBits=(DWORD)(sizeof(file)+offset);
    memcpy(bmp,&file,sizeof(file)); memcpy(bmp+sizeof(file),dib,length);
    int ok=wic_decode(factory,bmp,size,out);
    free(bmp); return ok;
}

static size_t png_encoded_size(const unsigned char *bytes,size_t length) {
    size_t offset=8;
    while (offset<=length && length-offset>=12) {
        uint32_t chunk=((uint32_t)bytes[offset]<<24)|((uint32_t)bytes[offset+1]<<16)|
            ((uint32_t)bytes[offset+2]<<8)|bytes[offset+3];
        if (chunk>length-offset-12) return 0;
        size_t end=offset+12+chunk;
        if (!memcmp(bytes+offset+4,"IEND",4)) return chunk==0 ? end : 0;
        offset=end;
    }
    return 0;
}

uint32_t zenit_win_clipboard_probe(void) {
    UINT png=RegisterClipboardFormatW(L"PNG");
    uint32_t kinds=IsClipboardFormatAvailable(CF_UNICODETEXT) ? 1 : 0;
    if ((png && IsClipboardFormatAvailable(png)) || IsClipboardFormatAvailable(CF_DIBV5) ||
        IsClipboardFormatAvailable(CF_DIB) || IsClipboardFormatAvailable(CF_BITMAP)) kinds|=2;
    if (IsClipboardFormatAvailable(CF_HDROP)) kinds|=4;
    return kinds;
}

/* Read one snapshot while holding the clipboard; never fetch length and data
   separately. WIC runs after closing it except for CF_BITMAP's borrowed handle. */
int zenit_win_clipboard_get_image(ZenitClipboardImage *out) {
    memset(out,0,sizeof(*out));
    HRESULT com=CoInitializeEx(NULL,COINIT_APARTMENTTHREADED);
    if (FAILED(com) && com!=RPC_E_CHANGED_MODE) return -1;
    IWICImagingFactory *factory=NULL;
    HRESULT hr=CoCreateInstance(&CLSID_WICImagingFactory,NULL,CLSCTX_INPROC_SERVER,&IID_IWICImagingFactory,(void **)&factory);
    int result=-1;
    unsigned char *png=NULL,*dib=NULL; size_t png_len=0,dib_len=0;
    if (FAILED(hr) || !clipboard_open(NULL)) goto done;
    UINT format=RegisterClipboardFormatW(L"PNG");
    uint32_t kinds=zenit_win_clipboard_probe();
    if (!(kinds&2)) { CloseClipboard(); result=0; goto done; }
    if (format && IsClipboardFormatAvailable(format)) png=copy_clip_global(format,&png_len);
    if (IsClipboardFormatAvailable(CF_DIBV5)) dib=copy_clip_global(CF_DIBV5,&dib_len);
    else if (IsClipboardFormatAvailable(CF_DIB)) dib=copy_clip_global(CF_DIB,&dib_len);
    int bitmap_ok=0;
    if (!png && !dib && IsClipboardFormatAvailable(CF_BITMAP)) {
        IWICBitmap *bitmap=NULL;
        HBITMAP handle=(HBITMAP)GetClipboardData(CF_BITMAP);
        if (handle && SUCCEEDED(IWICImagingFactory_CreateBitmapFromHBITMAP(factory,handle,NULL,WICBitmapIgnoreAlpha,&bitmap))) {
            bitmap_ok=wic_pixels(factory,(IWICBitmapSource *)bitmap,out);
            IWICBitmap_Release(bitmap);
        }
    }
    CloseClipboard();
    if (png && png_len>=8 && !memcmp(png,"\x89PNG\r\n\x1a\n",8) && png_encoded_size(png,png_len) && wic_decode(factory,png,png_len,out)) {
        out->raw=png; out->raw_len=png_encoded_size(png,png_len); png=NULL; result=1;
    } else if ((dib && wic_dib(factory,dib,dib_len,out)) || bitmap_ok) result=1;
    if (result==1) {
        size_t count=(size_t)out->width*out->height;
        for (size_t i=0;i<count;++i) for (unsigned c=0;c<3;++c)
            out->rgba[i*4+c]=(unsigned char)((out->rgba[i*4+c]*out->rgba[i*4+3]+127)/255);
    }
done:
    free(png); free(dib);
    if (factory) IWICImagingFactory_Release(factory);
    if (SUCCEEDED(com)) CoUninitialize();
    return result;
}

static HGLOBAL clipboard_memory(const void *bytes,size_t size) {
    HGLOBAL memory=GlobalAlloc(GMEM_MOVEABLE,size);
    if (!memory) return NULL;
    void *dest=GlobalLock(memory);
    if (!dest) { GlobalFree(memory); return NULL; }
    memcpy(dest,bytes,size); GlobalUnlock(memory); return memory;
}

int zenit_win_clipboard_set_image_png(void *owner,const unsigned char *bytes,size_t size) {
    if (!owner || !IsWindow((HWND)owner) || !bytes || size<8 || size>CLIP_ENCODED_LIMIT || memcmp(bytes,"\x89PNG\r\n\x1a\n",8) || !png_encoded_size(bytes,size)) return 0;
    HRESULT com=CoInitializeEx(NULL,COINIT_APARTMENTTHREADED);
    if (FAILED(com) && com!=RPC_E_CHANGED_MODE) return 0;
    IWICImagingFactory *factory=NULL;
    ZenitClipboardImage image={0};
    HGLOBAL png=NULL,dib=NULL;
    int ok=0;
    HRESULT hr=CoCreateInstance(&CLSID_WICImagingFactory,NULL,CLSCTX_INPROC_SERVER,&IID_IWICImagingFactory,(void **)&factory);
    if (FAILED(hr) || !wic_decode(factory,(unsigned char *)bytes,size,&image)) goto done;
    size_t count=(size_t)image.width*image.height;
    size_t dib_size=sizeof(BITMAPV5HEADER)+count*4;
    unsigned char *data=calloc(1,dib_size);
    if (!data) goto done;
    BITMAPV5HEADER *header=(BITMAPV5HEADER *)data;
    header->bV5Size=sizeof(*header); header->bV5Width=image.width; header->bV5Height=-(LONG)image.height;
    header->bV5Planes=1; header->bV5BitCount=32; header->bV5Compression=BI_BITFIELDS;
    header->bV5SizeImage=(DWORD)(count*4); header->bV5RedMask=0xff0000; header->bV5GreenMask=0xff00;
    header->bV5BlueMask=0xff; header->bV5AlphaMask=0xff000000; header->bV5CSType=LCS_sRGB;
    unsigned char *pixels=data+sizeof(*header);
    for (size_t i=0;i<count;++i) {
        pixels[i*4]=image.rgba[i*4+2]; pixels[i*4+1]=image.rgba[i*4+1];
        pixels[i*4+2]=image.rgba[i*4]; pixels[i*4+3]=image.rgba[i*4+3];
    }
    png=clipboard_memory(bytes,size); dib=clipboard_memory(data,dib_size); free(data);
    UINT format=RegisterClipboardFormatW(L"PNG");
    if (!png || !dib || !format || !clipboard_open((HWND)owner)) goto done;
    if (EmptyClipboard()) {
        if (SetClipboardData(format,png)) { png=NULL; ok=1; }
        if (ok && SetClipboardData(CF_DIBV5,dib)) dib=NULL;
        else ok=0;
    }
    CloseClipboard();
done:
    if (png) GlobalFree(png);
    if (dib) GlobalFree(dib);
    zenit_win_clipboard_free_image(&image);
    if (factory) IWICImagingFactory_Release(factory);
    if (SUCCEEDED(com)) CoUninitialize();
    return ok;
}
