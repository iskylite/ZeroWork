#include "../window_geometry.h"
#include <assert.h>
#include <stdio.h>

typedef struct { int border, caption, menu, threshold, calls; } Fixture;
static void query(void *raw, int w, int h, int *cw, int *ch) {
    Fixture *f=raw;
    ++f->calls;
    *cw=w-2*f->border;
    *ch=h-2*f->border-f->caption-f->menu*(w<f->threshold?2:1);
    if (*ch<0) *ch=0;
}
static void owner_geometry(void) {
    const ZenitGeometryRect work={0,0,1000,800};
    const ZenitGeometryRect frames[]={
        {-8,0,508,608}, {492,0,1008,608}, {-8,0,1008,808},
        {-108,0,408,608}, {-8,-100,508,508},
    };
    const ZenitGeometryRect visible[]={
        {0,0,500,600}, {500,0,1000,600}, {0,0,1000,800},
        {-100,0,400,600}, {0,-100,500,500},
    };
    for (unsigned i=0;i<sizeof(frames)/sizeof(frames[0]);++i) {
        ZenitGeometryRect out;
        assert(zenit_fit_owned_geometry(frames[i],visible[i],work,1,&out));
        assert(out.left==frames[i].left && out.top==frames[i].top &&
            out.right==frames[i].right && out.bottom==frames[i].bottom);
    }
    ZenitGeometryRect out;
    assert(zenit_fit_owned_geometry((ZenitGeometryRect){-108,0,1508,1008},
        (ZenitGeometryRect){-100,0,1500,1000},work,1,&out));
    assert(out.left==-108 && out.top==0 && out.right==908 && out.bottom==808);
    assert(zenit_fit_owned_geometry((ZenitGeometryRect){1092,900,1608,1508},
        (ZenitGeometryRect){1100,900,1600,1500},work,1,&out));
    assert(out.left==492 && out.top==200 && out.right==1008 && out.bottom==808);
    assert(zenit_fit_owned_geometry((ZenitGeometryRect){1092,900,1608,1508},
        (ZenitGeometryRect){1092,900,1608,1508},work,0,&out));
    assert(out.left==1092 && out.top==900 && out.right==1608 && out.bottom==1508);
    puts("owner geometry: 8 exact edge/Snap/partial/oversize/offscreen/fallback cases PASS");
}

int main(void) {
    owner_geometry();
    int cases=0;
    for (int dpi=96; dpi<=192; dpi+=24) {
        for (int custom=0; custom<2; ++custom) for (int menu=0; menu<2; ++menu) {
            Fixture f={.border=8*dpi/96,.caption=custom?0:24*dpi/96,
                .menu=menu?20*dpi/96:0,.threshold=700*dpi/96};
            const int cap_w=900*dpi/96,cap_h=700*dpi/96;
            for (int requested=670; requested<=710; ++requested) {
                int64_t wanted=((int64_t)requested*dpi+95)/96;
                int seed_w=(int)wanted+f.border; // Seed crosses a menu row threshold after width correction.
                int seed_h=301*dpi/96+2*f.border+f.caption+f.menu;
                int w,h; f.calls=0;
                assert(zenit_resolve_client_extent(wanted,(301*dpi+95)/96,cap_w,cap_h,
                    seed_w,seed_h,&f,query,&w,&h));
                assert(w==wanted+2*f.border);
                const int rows=w<f.threshold?2:1;
                assert(h==(301*dpi+95)/96+2*f.border+f.caption+rows*f.menu);
                assert(f.calls==3);
                ++cases;
            }
            int w,h; f.calls=0;
            const int tiny_w=(301*dpi+95)/96,tiny_h=(dpi+95)/96;
            assert(zenit_resolve_client_extent(tiny_w,tiny_h,cap_w,cap_h,
                tiny_w+2*f.border,tiny_h+2*f.border+f.caption+f.menu,&f,query,&w,&h));
            assert(w==tiny_w+2*f.border && h==tiny_h+2*f.border+f.caption+2*f.menu && f.calls==3);
            ++cases;
            f.calls=0;
            assert(zenit_resolve_client_extent(10000,10000,cap_w,cap_h,10000,10000,&f,query,&w,&h));
            assert(w==cap_w && h==cap_h && f.calls==3);
            ++cases;
        }
    }
    printf("window geometry: %d exact cases, 100/125/150/175/200%%, custom/menu/wrap/oversized PASS\n",cases);
}
