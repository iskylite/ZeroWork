/* Linux EGL 1.5 / OpenGL 4.3 context ownership. The ABI declarations below are
 * the standard EGL/GL entry-point types; no loader or platform headers are
 * required at build time. Reference: wgpu-hal/src/gles/egl.rs. */
#include "opengl_device.h"
#include <dlfcn.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Zig exports compiler-runtime memcmp from the executable. Resolve the
 * platform implementation explicitly so Debug recordings use libc's SIMD
 * comparison rather than that byte-wise fallback. pthread_once makes this
 * process-wide function-pointer cache safe across device/render threads. */
static pthread_once_t snapshot_compare_once = PTHREAD_ONCE_INIT;
static int (*snapshot_compare)(const void *, const void *, size_t);
static void init_snapshot_compare(void) {
    *(void **)(&snapshot_compare) = dlsym(RTLD_NEXT, "memcmp");
}
int zenit_gl_snapshot_equal(const unsigned char *a, const unsigned char *b, size_t len) {
    pthread_once(&snapshot_compare_once, init_snapshot_compare);
    if (snapshot_compare) return snapshot_compare(a, b, len) == 0;
    /* Static/no-next-library fallback: fixed-width unaligned-safe loads. */
    while (len >= 32) {
        uint64_t x[4], y[4];
        __builtin_memcpy(x, a, 32); __builtin_memcpy(y, b, 32);
        if ((x[0]^y[0]) | (x[1]^y[1]) | (x[2]^y[2]) | (x[3]^y[3])) return 0;
        a += 32; b += 32; len -= 32;
    }
    while (len--) if (*a++ != *b++) return 0;
    return 1;
}

_Static_assert(sizeof(ZenitGlDeviceInfo) == 940, "OpenGL info ABI");
_Static_assert(sizeof(ZenitGlDiagnostic) == 132, "OpenGL diagnostic ABI");

typedef void *EGLDisplay;
typedef void *EGLContext;
typedef void *EGLSurface;
typedef void *EGLConfig;
typedef int32_t EGLint;
typedef intptr_t EGLAttrib;
typedef uint32_t EGLBoolean;

typedef struct {
    EGLDisplay (*get_platform_display)(uint32_t, void *, const EGLAttrib *);
    EGLBoolean (*initialize)(EGLDisplay, EGLint *, EGLint *);
    EGLBoolean (*choose_config)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
    EGLBoolean (*bind_api)(uint32_t);
    EGLContext (*create_context)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
    EGLSurface (*create_surface)(EGLDisplay, EGLConfig, void *, const EGLAttrib *);
    EGLBoolean (*make_current)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
    EGLContext (*get_current_context)(void);
    EGLDisplay (*get_current_display)(void);
    EGLBoolean (*swap_interval)(EGLDisplay, EGLint);
    EGLBoolean (*swap_buffers)(EGLDisplay, EGLSurface);
    EGLBoolean (*destroy_surface)(EGLDisplay, EGLSurface);
    EGLBoolean (*destroy_context)(EGLDisplay, EGLContext);
    EGLBoolean (*terminate)(EGLDisplay);
    EGLint (*get_error)(void);
    const char *(*query_string)(EGLDisplay, EGLint);
    void *(*get_proc)(const char *);
    void *(*window_create)(void *, int, int);
    void (*window_resize)(void *, int, int, int, int);
    void (*window_destroy)(void *);
    const unsigned char *(*gl_get_string)(uint32_t);
    void (*gl_get_integer)(uint32_t, int *);
    uint32_t (*gl_get_error)(void);
    void (*gl_finish)(void);
    void (*gl_gen_queries)(int, uint32_t *);
    void (*gl_delete_queries)(int, const uint32_t *);
    void (*gl_get_query_iv)(uint32_t, uint32_t, int *);
    void (*gl_query_counter)(uint32_t, uint32_t);
    void (*gl_get_query_object_ui64v)(uint32_t, uint32_t, uint64_t *);
    void (*gl_gen_buffers)(int, uint32_t *);
    void (*gl_delete_buffers)(int, const uint32_t *);
    void (*gl_bind_buffer)(uint32_t, uint32_t);
    void (*gl_buffer_data)(uint32_t, intptr_t, const void *, uint32_t);
    void (*gl_buffer_sub_data)(uint32_t, intptr_t, intptr_t, const void *);
    void (*gl_get_buffer_sub_data)(uint32_t, intptr_t, intptr_t, void *);
    void (*gl_copy_buffer_sub_data)(uint32_t, uint32_t, intptr_t, intptr_t, intptr_t);
    uint32_t (*gl_create_shader)(uint32_t);
    void (*gl_shader_source)(uint32_t, int, const char *const *, const int *);
    void (*gl_compile_shader)(uint32_t);
    void (*gl_get_shader_iv)(uint32_t, uint32_t, int *);
    void (*gl_get_shader_info_log)(uint32_t, int, int *, char *);
    void (*gl_delete_shader)(uint32_t);
    uint32_t (*gl_create_program)(void);
    void (*gl_attach_shader)(uint32_t, uint32_t);
    void (*gl_link_program)(uint32_t);
    void (*gl_get_program_iv)(uint32_t, uint32_t, int *);
    void (*gl_get_program_info_log)(uint32_t, int, int *, char *);
    void (*gl_delete_program)(uint32_t);
    int (*gl_get_uniform_location)(uint32_t, const char *);
    void (*gl_program_uniform_1i)(uint32_t, int, int);
    void (*gl_use_program)(uint32_t);
    void (*gl_gen_vertex_arrays)(int, uint32_t *);
    void (*gl_delete_vertex_arrays)(int, const uint32_t *);
    void (*gl_bind_vertex_array)(uint32_t);
    void (*gl_bind_buffer_range)(uint32_t, uint32_t, uint32_t, intptr_t, intptr_t);
    void (*gl_active_texture)(uint32_t);
    void (*gl_bind_sampler)(uint32_t, uint32_t);
    void (*gl_viewport_indexed_f)(uint32_t, float, float, float, float);
    void (*gl_depth_range_f)(float, float);
    void (*gl_scissor)(int, int, int, int);
    void (*gl_blend_func_separate)(uint32_t, uint32_t, uint32_t, uint32_t);
    void (*gl_blend_equation_separate)(uint32_t, uint32_t);
    void (*gl_blend_color)(float, float, float, float);
    void (*gl_polygon_mode)(uint32_t, uint32_t);
    void (*gl_draw_arrays_instanced)(uint32_t, int, int, int);
    void (*gl_blit_framebuffer)(int, int, int, int, int, int, int, int, uint32_t, uint32_t);
    void (*gl_gen_samplers)(int, uint32_t *);
    void (*gl_delete_samplers)(int, const uint32_t *);
    void (*gl_sampler_parameter_i)(uint32_t, uint32_t, int);
    void (*gl_sampler_parameter_f)(uint32_t, uint32_t, float);
    void (*gl_sampler_parameter_fv)(uint32_t, uint32_t, const float *);
    void *(*gl_fence_sync)(uint32_t, uint32_t);
    void (*gl_delete_sync)(void *);
    uint32_t (*gl_client_wait_sync)(void *, uint32_t, uint64_t);
    void (*gl_flush)(void);
    void (*gl_gen_textures)(int, uint32_t *);
    void (*gl_delete_textures)(int, const uint32_t *);
    void (*gl_bind_texture)(uint32_t, uint32_t);
    void (*gl_tex_storage_2d)(uint32_t, int, uint32_t, int, int);
    void (*gl_tex_sub_image_2d)(uint32_t, int, int, int, int, int, uint32_t, uint32_t, const void *);
    void (*gl_tex_parameter_i)(uint32_t, uint32_t, int);
    void (*gl_pixel_store_i)(uint32_t, int);
    void (*gl_gen_framebuffers)(int, uint32_t *);
    void (*gl_delete_framebuffers)(int, const uint32_t *);
    void (*gl_bind_framebuffer)(uint32_t, uint32_t);
    void (*gl_framebuffer_texture_2d)(uint32_t, uint32_t, uint32_t, uint32_t, int);
    uint32_t (*gl_check_framebuffer_status)(uint32_t);
    void (*gl_read_pixels)(int, int, int, int, uint32_t, uint32_t, void *);
    void (*gl_copy_image_sub_data)(uint32_t, uint32_t, int, int, int, int, uint32_t, uint32_t, int, int, int, int, int, int, int);
    void (*gl_clear_buffer_fv)(uint32_t, int, const float *);
    void (*gl_color_mask)(unsigned char, unsigned char, unsigned char, unsigned char);
    unsigned char (*gl_is_enabled)(uint32_t);
    void (*gl_disable)(uint32_t);
    void (*gl_enable)(uint32_t);
    void (*gl_debug_callback)(void (*)(uint32_t, uint32_t, uint32_t, uint32_t, int, const char *, const void *), const void *);
} Api;
struct ZenitGlDevice {
    void *egl_library, *wayland_egl_library, *native_display;
    EGLDisplay display;
    EGLContext context;
    EGLSurface surface;
    void *window;
    void *wl_surface;
    Api api;
    pthread_t thread;
    uint32_t resources, validation_errors;
    uint32_t timer_queries[2];
    int timer_active;
    /* CPU time blocked on this submission's completion fence: the GPU work still
     * outstanding once every command was issued (a lower bound of GPU time). */
    uint64_t fence_wait_ns;
    int uniform_alignment, storage_alignment, uniform_limit, storage_limit, max_viewport[2];
    int initialized, claimed, current;
    struct ZenitGlDevice *next;
};
static pthread_mutex_t displays_mutex = PTHREAD_MUTEX_INITIALIZER;
static ZenitGlDevice *displays;
static int gl_result(ZenitGlDevice *, ZenitGlDiagnostic *, const char *);

static int fail(ZenitGlDiagnostic *diag, int status, const char *operation, uint32_t result) {
    if (diag) { snprintf(diag->operation, sizeof(diag->operation), "%s", operation); diag->api_result = result; }
    return status;
}
static int owner(ZenitGlDevice *d, ZenitGlDiagnostic *diag) {
    if (!d) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "null_device", 0);
    if (!pthread_equal(d->thread, pthread_self())) return fail(diag, ZENIT_GL_THREAD_VIOLATION, "render_thread", 0);
    return ZENIT_GL_OK;
}
static int egl_failure(ZenitGlDevice *d, ZenitGlDiagnostic *diag, const char *op) {
    return fail(diag, ZENIT_GL_API_FAILED, op, (uint32_t)d->api.get_error());
}
static int claim_display(ZenitGlDevice *d) {
    pthread_mutex_lock(&displays_mutex);
    for (ZenitGlDevice *it = displays; it; it = it->next) if (it->native_display == d->native_display) {
        pthread_mutex_unlock(&displays_mutex); return 0;
    }
    d->next = displays; displays = d; d->claimed = 1;
    pthread_mutex_unlock(&displays_mutex); return 1;
}
static void unclaim_display(ZenitGlDevice *d) {
    if (!d->claimed) return;
    pthread_mutex_lock(&displays_mutex);
    ZenitGlDevice **it = &displays;
    while (*it && *it != d) it = &(*it)->next;
    if (*it) *it = d->next;
    d->claimed = 0;
    pthread_mutex_unlock(&displays_mutex);
}
static void debug_message(uint32_t source, uint32_t type, uint32_t id, uint32_t severity,
    int length, const char *message, const void *user) {
    (void)source; (void)id;
    ZenitGlDevice *d = (ZenitGlDevice *)user;
    if (type == 0x824C || severity == 0x9146) {
        ++d->validation_errors;
        fprintf(stderr, "OPENGL_VALIDATION: %.*s\n", length > 512 ? 512 : length, message);
    }
}
static int software_renderer(const char *renderer) {
    char lower[256]; size_t i;
    for (i = 0; renderer[i] && i < sizeof(lower)-1; ++i) {
        unsigned char c = (unsigned char)renderer[i]; lower[i] = c >= 'A' && c <= 'Z' ? (char)(c + 'a' - 'A') : (char)c;
    }
    lower[i] = 0;
    return strstr(lower, "llvmpipe") || strstr(lower, "softpipe") || strstr(lower, "swiftshader") || strstr(lower, "swrast") || strstr(lower, "mesa offscreen");
}
static void copy_string(char *out, size_t capacity, const unsigned char *value) {
    snprintf(out, capacity, "%s", value ? (const char *)value : "");
}
void *zenit_gl_get_proc(ZenitGlDevice *d, const char *name) {
    if (!d || !name || !pthread_equal(d->thread, pthread_self())) return NULL;
    return d->api.get_proc(name);
}
int zenit_gl_make_current(ZenitGlDevice *d, ZenitGlDiagnostic *diag) {
    int status = owner(d, diag); if (status) return status;
    if (!d->context || !d->surface) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "device_retired", 0);
    if (d->api.get_current_context() == d->context && d->api.get_current_display() == d->display) { d->current = 1; return ZENIT_GL_OK; }
    if (!d->api.make_current(d->display, d->surface, d->surface, d->context)) return egl_failure(d, diag, "eglMakeCurrent");
    d->current = 1; return ZENIT_GL_OK;
}
int zenit_gl_release_current(ZenitGlDevice *d, ZenitGlDiagnostic *diag) {
    int status = owner(d, diag); if (status) return status;
    EGLContext active = d->api.get_current_context();
    if (active && (active != d->context || d->api.get_current_display() != d->display)) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "release_foreign_context", 0);
    if (!d->api.make_current(d->display, NULL, NULL, NULL)) return egl_failure(d, diag, "eglMakeCurrent(null)");
    d->current = 0; return ZENIT_GL_OK;
}
/* Wayland window hook (weak: probes link the GPU device without a window).
 * Sends the viewport destination that belongs to the buffer about to commit. */
__attribute__((weak)) void zenit_wayland_before_present(void *wl_surface, uint32_t pixel_width, uint32_t pixel_height);
void zenit_gl_before_swap(ZenitGlDevice *d, uint32_t width, uint32_t height) {
    if (zenit_wayland_before_present && d && d->wl_surface) zenit_wayland_before_present(d->wl_surface, width, height);
}
int zenit_gl_resize(ZenitGlDevice *d, uint32_t width, uint32_t height, ZenitGlDiagnostic *diag) {
    int status = owner(d, diag); if (status) return status;
    if (!d->window || !width || !height || width > INT_MAX || height > INT_MAX) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "window_extent", 0);
    d->api.window_resize(d->window, (int)width, (int)height, 0, 0); return ZENIT_GL_OK;
}
int zenit_gl_present(ZenitGlDevice *d, ZenitGlDiagnostic *diag) {
    int status = owner(d, diag); if (status) return status;
    if (!d->surface || d->api.get_current_context() != d->context || d->api.get_current_display() != d->display) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "present_without_current", 0);
    if (!d->api.swap_buffers(d->display, d->surface)) return egl_failure(d, diag, "eglSwapBuffers");
    return zenit_gl_release_current(d, diag);
}
uint32_t zenit_gl_validation_errors(const ZenitGlDevice *d) { return d && pthread_equal(d->thread, pthread_self()) ? d->validation_errors : UINT32_MAX; }
int zenit_gl_timer_begin(ZenitGlDevice *d, ZenitGlDiagnostic *diag) {
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    if (d->timer_active) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "timer_already_active", 0);
    int bits = 0;
    d->api.gl_get_query_iv(0x8E28, 0x8864, &bits); /* TIMESTAMP, QUERY_COUNTER_BITS */
    status = gl_result(d, diag, "timer_counter_bits"); if (status || !bits) return status;
    if (!d->timer_queries[0]) {
        d->api.gl_gen_queries(2, d->timer_queries);
        status = gl_result(d, diag, "timer_queries"); if (status) return status;
        if (!d->timer_queries[0] || !d->timer_queries[1]) return fail(diag, ZENIT_GL_API_FAILED, "timer_queries_zero", 0);
    }
    d->fence_wait_ns = 0;
    d->api.gl_query_counter(d->timer_queries[0], 0x8E28);
    status = gl_result(d, diag, "timer_begin");
    if (!status) d->timer_active = 1;
    return status;
}
int zenit_gl_timer_end(ZenitGlDevice *d, ZenitGlDiagnostic *diag) {
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    if (!d->timer_active) return ZENIT_GL_OK;
    if (d->timer_active != 1) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "timer_already_ended", 0);
    d->api.gl_query_counter(d->timer_queries[1], 0x8E28);
    status = gl_result(d, diag, "timer_end");
    d->timer_active = status ? 0 : 2;
    return status;
}
int zenit_gl_timer_finish(ZenitGlDevice *d, uint64_t *nanoseconds, uint32_t *valid, ZenitGlDiagnostic *diag) {
    if (!nanoseconds || !valid) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "timer_result", 0);
    *nanoseconds = 0; *valid = 0;
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    if (!d->timer_active) return ZENIT_GL_OK;
    if (d->timer_active != 2) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "timer_not_ended", 0);
    uint64_t available = 0;
    d->api.gl_get_query_object_ui64v(d->timer_queries[1], 0x8867, &available); /* QUERY_RESULT_AVAILABLE */
    status = gl_result(d, diag, "timer_available");
    d->timer_active = 0;
    if (status || !available) return status; /* never block waiting for a query */
    uint64_t start = 0, end = 0;
    d->api.gl_get_query_object_ui64v(d->timer_queries[0], 0x8866, &start);
    d->api.gl_get_query_object_ui64v(d->timer_queries[1], 0x8866, &end); /* QUERY_RESULT */
    status = gl_result(d, diag, "timer_finish");
    /* Do not publish wrapped, zero or failed samples as genuine GPU time. Some
     * virtual GPUs (vmwgfx/SVGA3D) stamp TIMESTAMP at command submission, so the
     * interval collapses to ~0 while the fence wait shows the real drain: report
     * the larger of the two. On hardware the timestamp interval dominates. */
    if (!status) {
        uint64_t elapsed = end > start ? end - start : 0;
        if (d->fence_wait_ns > elapsed) elapsed = d->fence_wait_ns;
        if (elapsed) { *nanoseconds = elapsed; *valid = 1; }
    }
    return status;
}
int zenit_gl_retain_resource(ZenitGlDevice *d, ZenitGlDiagnostic *diag) {
    int status = owner(d, diag); if (status) return status;
    if (!d->context || d->resources == UINT32_MAX) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "retain_resource", 0);
    ++d->resources; return ZENIT_GL_OK;
}
int zenit_gl_release_resource(ZenitGlDevice *d, ZenitGlDiagnostic *diag) {
    int status = owner(d, diag); if (status) return status;
    if (!d->resources) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "release_resource_underflow", 0);
    --d->resources; return ZENIT_GL_OK;
}
int zenit_gl_device_destroy(ZenitGlDevice *d, uint32_t *errors, ZenitGlDiagnostic *diag) {
    if (errors) *errors = 0;
    if (!d) return ZENIT_GL_OK;
    int status = owner(d, diag); if (status) return status;
    if (d->resources) return fail(diag, ZENIT_GL_RESOURCES_ALIVE, "device_resources_alive", d->resources);
    if (d->context && d->surface) {
        status = zenit_gl_make_current(d, diag); if (status) return status;
        d->api.gl_finish();
        if (d->timer_queries[0] || d->timer_queries[1]) {
            d->api.gl_delete_queries(2, d->timer_queries);
            d->timer_queries[0] = d->timer_queries[1] = 0;
            d->timer_active = 0;
        }
        status = zenit_gl_release_current(d, diag); if (status) return status;
    }
    if (d->surface) {
        if (!d->api.destroy_surface(d->display, d->surface)) return egl_failure(d, diag, "eglDestroySurface");
        d->surface = NULL;
    }
    if (d->window) { d->api.window_destroy(d->window); d->window = NULL; }
    if (d->context) {
        if (!d->api.destroy_context(d->display, d->context)) return egl_failure(d, diag, "eglDestroyContext");
        d->context = NULL;
    }
    if (d->initialized) {
        if (!d->api.terminate(d->display)) return egl_failure(d, diag, "eglTerminate");
        d->initialized = 0;
    }
    unclaim_display(d);
    if (d->wayland_egl_library) dlclose(d->wayland_egl_library);
    if (d->egl_library) dlclose(d->egl_library);
    if (errors) *errors = d->validation_errors;
    free(d); return ZENIT_GL_OK;
}
int zenit_gl_device_create(void *wl_display, void *wl_surface, uint32_t width, uint32_t height,
    int allow_software, int debug, ZenitGlDevice **out, ZenitGlDeviceInfo *info, ZenitGlDiagnostic *diag) {
    if (out) *out = NULL;
    if (!out || !info || !wl_display || !wl_surface || !width || !height || width > INT_MAX || height > INT_MAX)
        return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "create_arguments", 0);
    memset(info, 0, sizeof(*info));
    ZenitGlDevice *d = calloc(1, sizeof(*d));
    if (!d) return fail(diag, ZENIT_GL_OUT_OF_MEMORY, "device_allocate", 0);
    d->thread = pthread_self(); d->native_display = wl_display;
    int status = ZENIT_GL_API_FAILED;
    if (!claim_display(d)) { status = fail(diag, ZENIT_GL_DISPLAY_ALREADY_OWNED, "wl_display_already_owned", 0); goto failed; }
    d->egl_library = dlopen("libEGL.so.1", RTLD_NOW | RTLD_LOCAL);
    d->wayland_egl_library = dlopen("libwayland-egl.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!d->egl_library || !d->wayland_egl_library) { status = fail(diag, ZENIT_GL_LOADER_UNAVAILABLE, "EGL_runtime_libraries", 0); goto failed; }
#define LOAD(field, symbol, library) do { *(void **)(&d->api.field) = dlsym(library, symbol); if (!d->api.field) { status = fail(diag, ZENIT_GL_SYMBOL_UNAVAILABLE, symbol, 0); goto failed; } } while (0)
    LOAD(get_platform_display, "eglGetPlatformDisplay", d->egl_library);
    LOAD(initialize, "eglInitialize", d->egl_library); LOAD(choose_config, "eglChooseConfig", d->egl_library);
    LOAD(bind_api, "eglBindAPI", d->egl_library); LOAD(create_context, "eglCreateContext", d->egl_library);
    LOAD(create_surface, "eglCreatePlatformWindowSurface", d->egl_library); LOAD(make_current, "eglMakeCurrent", d->egl_library);
    LOAD(get_current_context, "eglGetCurrentContext", d->egl_library); LOAD(get_current_display, "eglGetCurrentDisplay", d->egl_library);
    LOAD(swap_interval, "eglSwapInterval", d->egl_library); LOAD(swap_buffers, "eglSwapBuffers", d->egl_library);
    LOAD(destroy_surface, "eglDestroySurface", d->egl_library); LOAD(destroy_context, "eglDestroyContext", d->egl_library);
    LOAD(terminate, "eglTerminate", d->egl_library); LOAD(get_error, "eglGetError", d->egl_library);
    LOAD(query_string, "eglQueryString", d->egl_library); LOAD(get_proc, "eglGetProcAddress", d->egl_library);
    LOAD(window_create, "wl_egl_window_create", d->wayland_egl_library);
    LOAD(window_resize, "wl_egl_window_resize", d->wayland_egl_library); LOAD(window_destroy, "wl_egl_window_destroy", d->wayland_egl_library);
#undef LOAD
#define EGL_CHECK(expression, name) do { if (!(expression)) { status = egl_failure(d, diag, name); goto failed; } } while (0)
    d->display = d->api.get_platform_display(0x31D8, wl_display, NULL);
    EGLint major, minor;
    EGL_CHECK(d->display, "eglGetPlatformDisplay(Wayland)");
    EGL_CHECK(d->api.initialize(d->display, &major, &minor), "eglInitialize"); d->initialized = 1;
    info->egl_major = (uint32_t)major; info->egl_minor = (uint32_t)minor;
    if (major < 1 || (major == 1 && minor < 5)) { status = fail(diag, ZENIT_GL_API_FAILED, "EGL_1_5_required", 0); goto failed; }
    const EGLint attrs[] = { 0x3033, 4, 0x3040, 8, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3032, 0, 0x3038 };
    EGLConfig config = NULL; EGLint count = 0;
    EGL_CHECK(d->api.choose_config(d->display, attrs, &config, 1, &count) && count, "eglChooseConfig");
    EGL_CHECK(d->api.bind_api(0x30A2), "eglBindAPI(OpenGL)");
    const EGLint context_attrs[] = { 0x3098, 4, 0x30FB, 3, 0x30FD, 1, 0x30FC, debug ? 1 : 0, 0x3038 };
    d->context = d->api.create_context(d->display, config, NULL, context_attrs); EGL_CHECK(d->context, "eglCreateContext(4.3 core)");
    d->wl_surface = wl_surface;
    d->window = d->api.window_create(wl_surface, (int)width, (int)height);
    if (!d->window) { status = fail(diag, ZENIT_GL_OUT_OF_MEMORY, "wl_egl_window_create", 0); goto failed; }
    d->surface = d->api.create_surface(d->display, config, d->window, NULL); EGL_CHECK(d->surface, "eglCreatePlatformWindowSurface");
    EGL_CHECK(d->api.make_current(d->display, d->surface, d->surface, d->context), "eglMakeCurrent"); d->current = 1;
    EGL_CHECK(d->api.swap_interval(d->display, 1), "eglSwapInterval");
#undef EGL_CHECK
#define GL_LOAD(field, name) do { *(void **)(&d->api.field) = d->api.get_proc(name); if (!d->api.field) { status = fail(diag, ZENIT_GL_SYMBOL_UNAVAILABLE, name, 0); goto failed; } } while (0)
    GL_LOAD(gl_get_string, "glGetString"); GL_LOAD(gl_get_integer, "glGetIntegerv"); GL_LOAD(gl_get_error, "glGetError"); GL_LOAD(gl_finish, "glFinish");
    GL_LOAD(gl_gen_queries, "glGenQueries"); GL_LOAD(gl_delete_queries, "glDeleteQueries");
    GL_LOAD(gl_get_query_iv, "glGetQueryiv"); GL_LOAD(gl_query_counter, "glQueryCounter");
    GL_LOAD(gl_get_query_object_ui64v, "glGetQueryObjectui64v");
    GL_LOAD(gl_gen_buffers, "glGenBuffers"); GL_LOAD(gl_delete_buffers, "glDeleteBuffers");
    GL_LOAD(gl_bind_buffer, "glBindBuffer"); GL_LOAD(gl_buffer_data, "glBufferData");
    GL_LOAD(gl_buffer_sub_data, "glBufferSubData"); GL_LOAD(gl_get_buffer_sub_data, "glGetBufferSubData");
    GL_LOAD(gl_copy_buffer_sub_data, "glCopyBufferSubData");
    GL_LOAD(gl_create_shader, "glCreateShader"); GL_LOAD(gl_shader_source, "glShaderSource");
    GL_LOAD(gl_compile_shader, "glCompileShader"); GL_LOAD(gl_get_shader_iv, "glGetShaderiv");
    GL_LOAD(gl_get_shader_info_log, "glGetShaderInfoLog"); GL_LOAD(gl_delete_shader, "glDeleteShader");
    GL_LOAD(gl_create_program, "glCreateProgram"); GL_LOAD(gl_attach_shader, "glAttachShader");
    GL_LOAD(gl_link_program, "glLinkProgram"); GL_LOAD(gl_get_program_iv, "glGetProgramiv");
    GL_LOAD(gl_get_program_info_log, "glGetProgramInfoLog"); GL_LOAD(gl_delete_program, "glDeleteProgram");
    GL_LOAD(gl_get_uniform_location, "glGetUniformLocation"); GL_LOAD(gl_program_uniform_1i, "glProgramUniform1i");
    GL_LOAD(gl_use_program, "glUseProgram"); GL_LOAD(gl_gen_vertex_arrays, "glGenVertexArrays");
    GL_LOAD(gl_delete_vertex_arrays, "glDeleteVertexArrays"); GL_LOAD(gl_bind_vertex_array, "glBindVertexArray");
    GL_LOAD(gl_bind_buffer_range, "glBindBufferRange"); GL_LOAD(gl_active_texture, "glActiveTexture");
    GL_LOAD(gl_bind_sampler, "glBindSampler"); GL_LOAD(gl_viewport_indexed_f, "glViewportIndexedf");
    GL_LOAD(gl_depth_range_f, "glDepthRangef"); GL_LOAD(gl_scissor, "glScissor");
    GL_LOAD(gl_blend_func_separate, "glBlendFuncSeparate"); GL_LOAD(gl_blend_equation_separate, "glBlendEquationSeparate");
    GL_LOAD(gl_blend_color, "glBlendColor"); GL_LOAD(gl_polygon_mode, "glPolygonMode");
    GL_LOAD(gl_draw_arrays_instanced, "glDrawArraysInstanced"); GL_LOAD(gl_blit_framebuffer, "glBlitFramebuffer");
    GL_LOAD(gl_gen_samplers, "glGenSamplers"); GL_LOAD(gl_delete_samplers, "glDeleteSamplers");
    GL_LOAD(gl_sampler_parameter_i, "glSamplerParameteri"); GL_LOAD(gl_sampler_parameter_f, "glSamplerParameterf");
    GL_LOAD(gl_sampler_parameter_fv, "glSamplerParameterfv");
    GL_LOAD(gl_fence_sync, "glFenceSync"); GL_LOAD(gl_delete_sync, "glDeleteSync");
    GL_LOAD(gl_client_wait_sync, "glClientWaitSync"); GL_LOAD(gl_flush, "glFlush");
    GL_LOAD(gl_gen_textures, "glGenTextures"); GL_LOAD(gl_delete_textures, "glDeleteTextures");
    GL_LOAD(gl_bind_texture, "glBindTexture"); GL_LOAD(gl_tex_storage_2d, "glTexStorage2D");
    GL_LOAD(gl_tex_sub_image_2d, "glTexSubImage2D"); GL_LOAD(gl_tex_parameter_i, "glTexParameteri");
    GL_LOAD(gl_pixel_store_i, "glPixelStorei");
    GL_LOAD(gl_gen_framebuffers, "glGenFramebuffers"); GL_LOAD(gl_delete_framebuffers, "glDeleteFramebuffers");
    GL_LOAD(gl_bind_framebuffer, "glBindFramebuffer"); GL_LOAD(gl_framebuffer_texture_2d, "glFramebufferTexture2D");
    GL_LOAD(gl_check_framebuffer_status, "glCheckFramebufferStatus"); GL_LOAD(gl_read_pixels, "glReadPixels");
    GL_LOAD(gl_copy_image_sub_data, "glCopyImageSubData"); GL_LOAD(gl_clear_buffer_fv, "glClearBufferfv");
    GL_LOAD(gl_color_mask, "glColorMask"); GL_LOAD(gl_is_enabled, "glIsEnabled");
    GL_LOAD(gl_disable, "glDisable"); GL_LOAD(gl_enable, "glEnable");
    if (debug) {
        GL_LOAD(gl_enable, "glEnable"); GL_LOAD(gl_debug_callback, "glDebugMessageCallback");
        d->api.gl_enable(0x92E0); d->api.gl_enable(0x8242); d->api.gl_debug_callback(debug_message, d);
    }
#undef GL_LOAD
    copy_string(info->vendor, sizeof(info->vendor), d->api.gl_get_string(0x1F00));
    copy_string(info->renderer, sizeof(info->renderer), d->api.gl_get_string(0x1F01));
    copy_string(info->version, sizeof(info->version), d->api.gl_get_string(0x1F02));
    info->software = (uint32_t)software_renderer(info->renderer);
    if (!info->renderer[0] || !info->version[0]) { status = fail(diag, ZENIT_GL_API_FAILED, "GL_context_strings", 0); goto failed; }
    if (info->software && !allow_software) { status = fail(diag, ZENIT_GL_SOFTWARE_REJECTED, "software_renderer_rejected", 0); goto failed; }
    const char *extensions = d->api.query_string(d->display, 0x3055);
    if (extensions && strstr(extensions, "EGL_MESA_query_driver")) {
        const char *(*get_driver)(EGLDisplay) = NULL;
        *(void **)(&get_driver) = d->api.get_proc("eglGetDisplayDriverName");
        if (get_driver) copy_string(info->driver, sizeof(info->driver), (const unsigned char *)get_driver(d->display));
    }
#define LIMIT(field, token) do { int value = 0; d->api.gl_get_integer(token, &value); if (value <= 0) { status = fail(diag, ZENIT_GL_API_FAILED, "GL_limit_" #field, (uint32_t)value); goto failed; } info->field = (uint32_t)value; } while (0)
    LIMIT(max_texture_size, 0x0D33); LIMIT(uniform_buffer_bindings, 0x8A2F); LIMIT(uniform_block_size, 0x8A30);
    LIMIT(storage_buffer_bindings, 0x90DD); LIMIT(vertex_storage_blocks, 0x90D6); LIMIT(fragment_storage_blocks, 0x90DA);
    LIMIT(fragment_texture_units, 0x8872); LIMIT(combined_texture_units, 0x8B4D);
#undef LIMIT
    uint32_t gl_error = d->api.gl_get_error();
    if (gl_error) { status = fail(diag, ZENIT_GL_API_FAILED, "GL_initialization", gl_error); goto failed; }
    *out = d; return ZENIT_GL_OK;
failed:
    /* Creation failures never publish ownership. All loaded API entries used
     * here precede their corresponding objects, including partial contexts. */
    if (d->current && d->api.make_current) d->api.make_current(d->display, NULL, NULL, NULL);
    if (d->surface) d->api.destroy_surface(d->display, d->surface);
    if (d->window) d->api.window_destroy(d->window);
    if (d->context) d->api.destroy_context(d->display, d->context);
    if (d->initialized) d->api.terminate(d->display);
    unclaim_display(d);
    if (d->wayland_egl_library) dlclose(d->wayland_egl_library);
    if (d->egl_library) dlclose(d->egl_library);
    free(d); return status;
}

#include "opengl_resources.inc"

#include "opengl_pipeline.inc"
