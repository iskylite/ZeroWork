#include "../native/windows/dwrite_bridge.cpp"
#include <assert.h>
int main() {
    auto *context=zenit_dwrite_raster_context_create();assert(context);
    float params[8];assert(zenit_dwrite_raster_context_refresh(context,nullptr,0,params)==1);
    assert(SUCCEEDED(OleInitialize(nullptr)));
    APTTYPE type;APTTYPEQUALIFIER qualifier;assert(SUCCEEDED(CoGetApartmentType(&type,&qualifier)));
    assert(type==APTTYPE_STA || type==APTTYPE_MAINSTA);
    auto *font=zenit_dwrite_find_font("Microsoft YaHei UI","zh-CN",12,400,0);assert(font);
    uint32_t glyph=zenit_dwrite_glyph_index(font,0x6625);
    for(int i=0;i<1000;i++) {
        uint8_t *pixels=nullptr;uint32_t width,height,color;int32_t x,y,advance;
        uint32_t lcd=params[7]!=0 && i%2;
        assert(zenit_dwrite_rasterize_glyph_context(context,font,glyph,2,(i%4)*.25f,0,lcd,&pixels,&width,&height,&x,&y,&advance,&color)==0);
        assert(width>0 && height>0 && color==(lcd?2u:0u));zenit_dwrite_free_bitmap(pixels);
    }
    assert(zenit_dwrite_raster_context_target_allocations(context)==1);
    assert(zenit_dwrite_raster_context_refresh(context,nullptr,0,params)==0);
    assert(zenit_dwrite_raster_context_refresh(context,nullptr,1,params)==1);
    assert(zenit_dwrite_raster_context_target_allocations(context)==1);
    zenit_dwrite_release_font(font);OleUninitialize();zenit_dwrite_raster_context_destroy(context);
}
