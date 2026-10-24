#ifndef ZENIT_D2D_COMPOSITE_H
#define ZENIT_D2D_COMPOSITE_H
/* C ABI around D2D 1.1; MinGW omits C declarations for ID2D1Effect. */
#ifdef __cplusplus
extern "C" {
#endif
typedef struct ZenitBackdrop {
    float radius, level, saturation, brightness;
    unsigned direction, count;
    float strength, positions[4], strengths[4];
    float matrix[6];
    uint32_t owner_id;
    float tint[4], thickness;
    float optic[4], specular[4], surface[4], bottom[4], lens[4], radii[4];
} ZenitBackdrop;
typedef struct ZenitLuminance { uint32_t owner_id; float value; } ZenitLuminance;
typedef struct ZenitDamageItem { uint64_t digest; float bounds[4]; } ZenitDamageItem;
typedef struct ZenitRetainedInfo {
    uint32_t id, count;
    uint64_t hash;
    const ZenitDamageItem *damage;
    uint32_t safe;
} ZenitRetainedInfo;
typedef struct ZenitGradient {
    uint32_t count, direction, extend, shape;
    float center[2], radius[2];
    float colors[16][4], positions[16];
    float start_angle, conic_phase;
} ZenitGradient;
typedef struct ZenitNoise { uint32_t mode, seed; float scale, intensity; } ZenitNoise;
int zenit_d2d_noise_brush(ID2D1RenderTarget *,const D2D1_RECT_F *,const ZenitNoise *,const D2D1_COLOR_F *,uint32_t,float,float,ID2D1Brush **);
void zenit_d2d_composite_offset(void *,float *,float *);
int zenit_d2d_gradient_brush(ID2D1RenderTarget *, const D2D1_RECT_F *, const ZenitGradient *, ID2D1Brush **);
typedef struct ZenitRetainedStats { uint32_t hits, misses, partial; } ZenitRetainedStats;
void *zenit_d2d_retained_create(void);
void zenit_d2d_retained_destroy(void *);
void zenit_d2d_retained_stats(void *, ZenitRetainedStats *);
void *zenit_d2d_retained_begin(void *, ID2D1RenderTarget **,
    const D2D1_MATRIX_3X2_F *, const D2D1_RECT_F *, ID2D1Geometry *, float,
    uint64_t *, void *, const ZenitRetainedInfo *, int, int *);
void *zenit_d2d_luminance_create(ID3D11Device *, void *);
void zenit_d2d_luminance_destroy(void *);
void zenit_d2d_luminance_begin_frame(void *);
unsigned zenit_d2d_luminance_read(void *, ZenitLuminance *, unsigned);
int zenit_d2d_create_device(ID3D11Device *, void **, ID2D1Factory **);
int zenit_d2d_create_target(void *, IDXGISwapChain *, ID2D1RenderTarget **);
void zenit_d2d_release_target(ID2D1RenderTarget *);
void zenit_d2d_release_device(void *);
void *zenit_d2d_composite_begin(void *, ID2D1RenderTarget **,
    const D2D1_MATRIX_3X2_F *, const D2D1_RECT_F *, ID2D1Geometry *,
    float, unsigned, int, uint64_t *);
void *zenit_d2d_composite_begin_padded(void *, ID2D1RenderTarget **,
    const D2D1_MATRIX_3X2_F *, const D2D1_RECT_F *, ID2D1Geometry *,
    float, unsigned, int, uint64_t *, float);
int zenit_d2d_composite_end(void *, ID2D1RenderTarget **, int);
int zenit_d2d_backdrop(void *, ID2D1RenderTarget **, const D2D1_RECT_F *,
    ID2D1Geometry *, const ZenitBackdrop *, uint64_t *, void *);
#ifdef __cplusplus
}
#endif
#endif
