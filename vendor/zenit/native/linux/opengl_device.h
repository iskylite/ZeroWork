#ifndef ZENIT_OPENGL_DEVICE_H
#define ZENIT_OPENGL_DEVICE_H
#include <stdint.h>
#include <stddef.h>

int zenit_gl_snapshot_equal(const unsigned char *, const unsigned char *, size_t);

typedef struct ZenitGlDevice ZenitGlDevice;
typedef struct {
    char vendor[256], renderer[256], version[256], driver[128];
    uint32_t software, egl_major, egl_minor, max_texture_size, uniform_buffer_bindings, uniform_block_size;
    uint32_t storage_buffer_bindings, vertex_storage_blocks, fragment_storage_blocks;
    uint32_t fragment_texture_units, combined_texture_units;
} ZenitGlDeviceInfo;
typedef struct { char operation[128]; uint32_t api_result; } ZenitGlDiagnostic;
enum {
    ZENIT_GL_OK = 0, ZENIT_GL_INVALID_ARGUMENT = 1,
    ZENIT_GL_LOADER_UNAVAILABLE = 2, ZENIT_GL_SYMBOL_UNAVAILABLE = 3,
    ZENIT_GL_API_FAILED = 4, ZENIT_GL_SOFTWARE_REJECTED = 5,
    ZENIT_GL_OUT_OF_MEMORY = 6, ZENIT_GL_THREAD_VIOLATION = 7,
    ZENIT_GL_DISPLAY_ALREADY_OWNED = 8, ZENIT_GL_RESOURCES_ALIVE = 9
};
/* Single render thread; borrow native Wayland objects until checked destroy.
 * Duplicate device ownership of one wl_display is rejected, so EGLTerminate
 * cannot invalidate another device's context. Software use is opt-in. */
int zenit_gl_device_create(void *wl_display, void *wl_surface, uint32_t width,
    uint32_t height, int allow_software, int debug, ZenitGlDevice **out,
    ZenitGlDeviceInfo *info, ZenitGlDiagnostic *diagnostic);
int zenit_gl_device_destroy(ZenitGlDevice *, uint32_t *validation_errors, ZenitGlDiagnostic *);
int zenit_gl_make_current(ZenitGlDevice *, ZenitGlDiagnostic *);
int zenit_gl_release_current(ZenitGlDevice *, ZenitGlDiagnostic *);
int zenit_gl_resize(ZenitGlDevice *, uint32_t width, uint32_t height, ZenitGlDiagnostic *);
int zenit_gl_present(ZenitGlDevice *, ZenitGlDiagnostic *);
void *zenit_gl_get_proc(ZenitGlDevice *, const char *name);
uint32_t zenit_gl_validation_errors(const ZenitGlDevice *);
int zenit_gl_timer_begin(ZenitGlDevice *, ZenitGlDiagnostic *);
int zenit_gl_timer_end(ZenitGlDevice *, ZenitGlDiagnostic *);
int zenit_gl_timer_finish(ZenitGlDevice *, uint64_t *nanoseconds, uint32_t *valid, ZenitGlDiagnostic *);
int zenit_gl_retain_resource(ZenitGlDevice *, ZenitGlDiagnostic *);
int zenit_gl_release_resource(ZenitGlDevice *, ZenitGlDiagnostic *);
typedef struct ZenitGlBuffer ZenitGlBuffer;
int zenit_gl_buffer_create(ZenitGlDevice *, uint64_t size, uint32_t usage, ZenitGlBuffer **out, ZenitGlDiagnostic *);
int zenit_gl_buffer_destroy(ZenitGlBuffer *, ZenitGlDiagnostic *);
int zenit_gl_buffer_write(ZenitGlBuffer *, uint64_t offset, const uint8_t *, size_t, ZenitGlDiagnostic *);
int zenit_gl_buffer_read(ZenitGlBuffer *, uint64_t offset, uint8_t *, size_t, ZenitGlDiagnostic *);
int zenit_gl_buffer_copy(ZenitGlBuffer *src, uint64_t src_offset, ZenitGlBuffer *dst, uint64_t dst_offset, uint64_t size, ZenitGlDiagnostic *);
typedef struct ZenitGlTexture ZenitGlTexture;
int zenit_gl_texture_create(ZenitGlDevice *, uint32_t width, uint32_t height, uint32_t format, ZenitGlTexture **out, ZenitGlDiagnostic *);
int zenit_gl_texture_destroy(ZenitGlTexture *, ZenitGlDiagnostic *);
int zenit_gl_texture_clear(ZenitGlTexture *, const float rgba[4], ZenitGlDiagnostic *);
int zenit_gl_texture_transfer(ZenitGlTexture *, uint32_t x, uint32_t y, uint32_t width, uint32_t height, uint8_t *, size_t length, uint32_t stride, int upload, ZenitGlDiagnostic *);
int zenit_gl_texture_copy(ZenitGlTexture *, uint32_t x, uint32_t y, ZenitGlTexture *, uint32_t dx, uint32_t dy, uint32_t width, uint32_t height, ZenitGlDiagnostic *);
typedef struct ZenitGlSampler ZenitGlSampler;
typedef struct {
    uint32_t mag_filter, min_filter, mipmap_filter, address_u, address_v, address_w;
    float lod_min, lod_max;
} ZenitGlSamplerDescriptor;
int zenit_gl_sampler_create_descriptor(ZenitGlDevice *, const ZenitGlSamplerDescriptor *, ZenitGlSampler **out, ZenitGlDiagnostic *);
int zenit_gl_sampler_destroy(ZenitGlSampler *, ZenitGlDiagnostic *);
typedef struct ZenitGlFence ZenitGlFence;
int zenit_gl_fence_create(ZenitGlDevice *, ZenitGlFence **out, ZenitGlDiagnostic *);
int zenit_gl_fence_wait(ZenitGlFence *, uint64_t timeout_ns, uint32_t *completed, ZenitGlDiagnostic *);
/* Retirement keeps ownership intact on timeout. completed=0 is not an API
 * failure, and the fence remains a live device lease until actual retirement. */
int zenit_gl_fence_retire(ZenitGlFence *, uint64_t timeout_ns, uint32_t *completed, ZenitGlDiagnostic *);
typedef struct ZenitGlPipeline ZenitGlPipeline;
typedef struct { uint32_t group, binding, kind, stages; } ZenitGlPipelineBinding;
typedef struct { const char *code; size_t length; } ZenitGlShaderCode;
typedef struct {
    uint32_t unit, texture_group, texture_binding, sampler_group, sampler_binding;
    const char *uniform_name;
} ZenitGlTextureUnit;
typedef struct {
    uint32_t format, blend_enabled, source_rgb, destination_rgb, rgb_operation;
    uint32_t source_alpha, destination_alpha, alpha_operation;
} ZenitGlPipelineState;
typedef struct { uint32_t group, binding, kind; void *resource; uint64_t offset, size; } ZenitGlDrawBinding;
typedef struct { float viewport[6]; uint32_t scissor[4]; } ZenitGlDrawRegion;
int zenit_gl_pipeline_create_configured(ZenitGlDevice *, const ZenitGlShaderCode *vertex,
    const ZenitGlShaderCode *fragment, const ZenitGlPipelineBinding *, uint32_t count,
    const ZenitGlTextureUnit *, uint32_t unit_count, const ZenitGlPipelineState *,
    ZenitGlPipeline **out, ZenitGlDiagnostic *);
int zenit_gl_pipeline_destroy(ZenitGlPipeline *, ZenitGlDiagnostic *);
int zenit_gl_pipeline_draw_region(ZenitGlPipeline *, ZenitGlTexture *, const ZenitGlDrawBinding *, uint32_t count,
    uint32_t first_vertex, uint32_t vertices, uint32_t first_instance, uint32_t instances,
    const float *clear, const ZenitGlDrawRegion *, ZenitGlDiagnostic *);
/* Flip UI-top framebuffer rows only at native presentation. */
int zenit_gl_present_texture(ZenitGlDevice *, ZenitGlTexture *, uint32_t width, uint32_t height, ZenitGlDiagnostic *);
#endif
