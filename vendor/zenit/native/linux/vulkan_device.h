#ifndef ZENIT_VULKAN_DEVICE_H
#define ZENIT_VULKAN_DEVICE_H
#include <stddef.h>
#include <stdint.h>

typedef struct ZenitVkDevice ZenitVkDevice;
typedef struct {
    char name[256];
    uint32_t api_version;
    uint32_t driver_version;
    uint32_t vendor_id;
    uint32_t device_id;
    uint32_t device_type;
    uint32_t queue_family;
    uint32_t max_image_dimension_2d;
} ZenitVkDeviceInfo;

/* Caller-owned diagnostics also work when device creation fails. */
typedef struct {
    char operation[128];
    int32_t vk_result;
} ZenitVkDiagnostic;

enum {
    ZENIT_VK_OK = 0,
    ZENIT_VK_LOADER_UNAVAILABLE = 1,
    ZENIT_VK_SYMBOL_UNAVAILABLE = 2,
    ZENIT_VK_NO_DEVICE = 3,
    ZENIT_VK_SOFTWARE_ONLY = 4,
    ZENIT_VK_API_FAILED = 5,
    ZENIT_VK_INVALID_ARGUMENT = 6,
    ZENIT_VK_OUT_OF_MEMORY = 7,
    ZENIT_VK_VALIDATION_UNAVAILABLE = 8,
    ZENIT_VK_SURFACE_OUTDATED = 9,
    ZENIT_VK_SURFACE_LOST = 10,
    ZENIT_VK_TIMEOUT = 11,
    ZENIT_VK_RESOURCES_ALIVE = 12,
};

int zenit_vk_device_create(int allow_software, int require_validation,
                           void *wayland_display, void *wayland_surface,
                           ZenitVkDevice **out, ZenitVkDeviceInfo *info,
                           ZenitVkDiagnostic *diagnostic);
/* Nonnegative: validation error count. Negative: presentation retirement
 * failed (-1), or resources are still alive (-2); ownership stays with the
 * caller and destruction may be retried. */
int32_t zenit_vk_device_destroy(ZenitVkDevice *device);
uint32_t zenit_vk_validation_errors(const ZenitVkDevice *device);
int zenit_vk_present_clear(ZenitVkDevice *device, uint32_t width, uint32_t height,
                           const float rgba[4], ZenitVkDiagnostic *diagnostic);

/* Resource ownership stays with the caller until explicit destruction.
 * All transfer calls complete before returning; queue access is single-threaded.
 * Format: 1=R8_UNORM, 2=RGBA8_UNORM, 3=BGRA8_UNORM. */
typedef struct ZenitVkBuffer ZenitVkBuffer;
typedef struct ZenitVkTexture ZenitVkTexture;
/* Borrow an initialized BGRA8 texture through submission completion, copy it
 * into the acquired swapchain image, and retain presentation-fence ownership.
 * Texture and Wayland pixel dimensions must match; caller recreates on resize. */
int zenit_vk_present_texture(ZenitVkDevice *, ZenitVkTexture *, ZenitVkDiagnostic *);
int zenit_vk_buffer_create(ZenitVkDevice *, uint64_t size, uint32_t usage,
                           ZenitVkBuffer **out, ZenitVkDiagnostic *);
void zenit_vk_buffer_destroy(ZenitVkBuffer *);
int zenit_vk_buffer_write(ZenitVkBuffer *, uint64_t offset, const uint8_t *, size_t, ZenitVkDiagnostic *);
int zenit_vk_buffer_read(ZenitVkBuffer *, uint64_t offset, uint8_t *, size_t, ZenitVkDiagnostic *);
int zenit_vk_buffer_copy(ZenitVkBuffer *src, uint64_t src_offset, ZenitVkBuffer *dst,
                         uint64_t dst_offset, uint64_t size, ZenitVkDiagnostic *);
int zenit_vk_texture_create(ZenitVkDevice *, uint32_t width, uint32_t height,
                            uint32_t format, ZenitVkTexture **out, ZenitVkDiagnostic *);
void zenit_vk_texture_destroy(ZenitVkTexture *);
int zenit_vk_texture_clear(ZenitVkTexture *, const float rgba[4], ZenitVkDiagnostic *);
int zenit_vk_texture_copy(ZenitVkTexture *source, uint32_t source_x, uint32_t source_y,
    ZenitVkTexture *destination, uint32_t destination_x, uint32_t destination_y,
    uint32_t width, uint32_t height, ZenitVkDiagnostic *);
int zenit_vk_texture_transfer(ZenitVkTexture *, uint32_t x, uint32_t y,
                              uint32_t width, uint32_t height, uint8_t *bytes,
                              size_t length, uint32_t stride, int upload, ZenitVkDiagnostic *);

typedef struct ZenitVkPipeline ZenitVkPipeline;
typedef struct {
    uint32_t group, binding, kind, stages;
} ZenitVkPipelineBinding;
typedef struct {
    const uint32_t *code;
    size_t length;
    const char *entry;
} ZenitVkShaderCode;
/* Bindings: 0=uniform buffer, 1=sampled image, 2=storage buffer, 4=sampler.
 * Stages: bit 0=vertex, bit 1=fragment. Blend defaults to premultiplied alpha. */
int zenit_vk_pipeline_create(ZenitVkDevice *, const ZenitVkShaderCode *vertex,
                             const ZenitVkShaderCode *fragment,
                             const ZenitVkPipelineBinding *, uint32_t binding_count,
                             uint32_t format, ZenitVkPipeline **out, ZenitVkDiagnostic *);
typedef struct {
    uint32_t format, blend_enabled;
    uint32_t source_rgb, destination_rgb, rgb_operation;
    uint32_t source_alpha, destination_alpha, alpha_operation;
} ZenitVkPipelineState;
/* Blend factors use the renderer order: zero, one, src_color,
 * one_minus_src_color, src_alpha, one_minus_src_alpha, dst_color,
 * one_minus_dst_color, dst_alpha, one_minus_dst_alpha, src_alpha_saturated,
 * blend_color, one_minus_blend_color, blend_alpha, one_minus_blend_alpha.
 * Operations: add, subtract, reverse_subtract, min, max. */
int zenit_vk_pipeline_create_configured(ZenitVkDevice *, const ZenitVkShaderCode *,
    const ZenitVkShaderCode *, const ZenitVkPipelineBinding *, uint32_t,
    const ZenitVkPipelineState *, ZenitVkPipeline **, ZenitVkDiagnostic *);
void zenit_vk_pipeline_destroy(ZenitVkPipeline *);

typedef struct ZenitVkSampler ZenitVkSampler;
typedef struct {
    uint32_t mag_filter, min_filter, mipmap_filter;
    uint32_t address_u, address_v, address_w;
    float lod_min, lod_max;
} ZenitVkSamplerDescriptor;
int zenit_vk_sampler_create_descriptor(ZenitVkDevice *, const ZenitVkSamplerDescriptor *, ZenitVkSampler **out, ZenitVkDiagnostic *);
int zenit_vk_sampler_create(ZenitVkDevice *, int linear, int repeat, ZenitVkSampler **out, ZenitVkDiagnostic *);
void zenit_vk_sampler_destroy(ZenitVkSampler *);
typedef struct {
    uint32_t group, binding, kind;
    void *resource;
    uint64_t offset, size;
} ZenitVkDrawBinding;
typedef struct {
    float viewport[6]; /* x,y,width,height,min_depth,max_depth */
    uint32_t scissor[4]; /* x,y,width,height; zero extent is legal */
} ZenitVkDrawRegion;
int zenit_vk_pipeline_draw_region(ZenitVkPipeline *, ZenitVkTexture *,
    const ZenitVkDrawBinding *, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    const float *, const ZenitVkDrawRegion *, ZenitVkDiagnostic *);
/* Synchronous draw: resources are borrowed until this call returns. Target
 * must be initialized unless clear is non-null. Sampling the target is invalid. */
int zenit_vk_pipeline_draw(ZenitVkPipeline *, ZenitVkTexture *target,
                           const ZenitVkDrawBinding *, uint32_t binding_count,
                           uint32_t first_vertex, uint32_t vertices,
                           uint32_t first_instance, uint32_t instances,
                           const float *clear_rgba, ZenitVkDiagnostic *);

/* Exercise a real graphics pipeline, rasterization, barriers and staging
 * readback. Output is tightly packed BGRA8, matching Zenit's color format.
 * This bootstrap API is not the full renderer backend contract. */
int zenit_vk_render_probe(ZenitVkDevice *device, uint32_t width, uint32_t height,
                          uint8_t *bgra, size_t length,
                          const uint32_t *vertex_spirv, size_t vertex_size,
                          const uint32_t *fragment_spirv, size_t fragment_size,
                          ZenitVkDiagnostic *diagnostic);
#endif
