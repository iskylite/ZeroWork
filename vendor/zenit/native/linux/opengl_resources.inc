/* Native owned GL resources. Transfer APIs preserve device and byte-range
 * contracts and never issue a GL call for an invalid descriptor. */
struct ZenitGlBuffer {
    ZenitGlDevice *device;
    uint64_t size;
    uint32_t usage, id;
};
static int gl_result(ZenitGlDevice *d, ZenitGlDiagnostic *diag, const char *operation) {
    uint32_t error = d->api.gl_get_error();
    return error ? fail(diag, error == 0x0505 ? ZENIT_GL_OUT_OF_MEMORY : ZENIT_GL_API_FAILED, operation, error) : ZENIT_GL_OK;
}
int zenit_gl_buffer_create(ZenitGlDevice *d, uint64_t size, uint32_t usage, ZenitGlBuffer **out, ZenitGlDiagnostic *diag) {
    if (out) *out = NULL;
    if (!out || !size || size > INTPTR_MAX || !usage || (usage & ~1023u)) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "buffer_descriptor", 0);
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    ZenitGlBuffer *b = calloc(1, sizeof(*b));
    if (!b) return fail(diag, ZENIT_GL_OUT_OF_MEMORY, "buffer_owner", 0);
    void *zero = calloc(1, (size_t)size);
    if (!zero) { free(b); return fail(diag, ZENIT_GL_OUT_OF_MEMORY, "buffer_initial_zeroes", 0); }
    b->device = d; b->size = size; b->usage = usage;
    d->api.gl_gen_buffers(1, &b->id);
    d->api.gl_bind_buffer(0x8F37, b->id);
    d->api.gl_buffer_data(0x8F37, (intptr_t)size, zero, 0x88E8);
    free(zero);
    status = gl_result(d, diag, "glBufferData");
    if (!status && !b->id) status = fail(diag, ZENIT_GL_API_FAILED, "glGenBuffers", 0);
    if (!status) status = zenit_gl_retain_resource(d, diag);
    if (status) { if (b->id) d->api.gl_delete_buffers(1, &b->id); free(b); return status; }
    *out = b; return ZENIT_GL_OK;
}
int zenit_gl_buffer_destroy(ZenitGlBuffer *b, ZenitGlDiagnostic *diag) {
    if (!b) return ZENIT_GL_OK;
    ZenitGlDevice *d = b->device;
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    d->api.gl_delete_buffers(1, &b->id);
    status = gl_result(d, diag, "glDeleteBuffers"); if (status) return status;
    status = zenit_gl_release_resource(d, diag); if (status) return status;
    free(b); return ZENIT_GL_OK;
}
int zenit_gl_buffer_write(ZenitGlBuffer *b, uint64_t offset, const uint8_t *bytes, size_t length, ZenitGlDiagnostic *diag) {
    if (!b || (!bytes && length) || offset > b->size || length > b->size - offset) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "buffer_write_range", 0);
    int status = zenit_gl_make_current(b->device, diag); if (status) return status;
    if (!length) return ZENIT_GL_OK;
    b->device->api.gl_bind_buffer(0x8F37, b->id);
    b->device->api.gl_buffer_sub_data(0x8F37, (intptr_t)offset, (intptr_t)length, bytes);
    return gl_result(b->device, diag, "glBufferSubData");
}
int zenit_gl_buffer_read(ZenitGlBuffer *b, uint64_t offset, uint8_t *bytes, size_t length, ZenitGlDiagnostic *diag) {
    if (!b || (!bytes && length) || offset > b->size || length > b->size - offset) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "buffer_read_range", 0);
    int status = zenit_gl_make_current(b->device, diag); if (status) return status;
    if (!length) return ZENIT_GL_OK;
    b->device->api.gl_bind_buffer(0x8F36, b->id);
    b->device->api.gl_get_buffer_sub_data(0x8F36, (intptr_t)offset, (intptr_t)length, bytes);
    return gl_result(b->device, diag, "glGetBufferSubData");
}
int zenit_gl_buffer_copy(ZenitGlBuffer *src, uint64_t src_offset, ZenitGlBuffer *dst, uint64_t dst_offset, uint64_t size, ZenitGlDiagnostic *diag) {
    if (!src || !dst || src->device != dst->device || !size || src_offset > src->size || size > src->size - src_offset ||
        dst_offset > dst->size || size > dst->size - dst_offset ||
        (src == dst && src_offset < dst_offset + size && dst_offset < src_offset + size))
        return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "buffer_copy_range_or_device", 0);
    ZenitGlDevice *d = src->device;
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    d->api.gl_bind_buffer(0x8F36, src->id); d->api.gl_bind_buffer(0x8F37, dst->id);
    // Ordered with every later command of this context (and CPU reads such as
    // glGetBufferSubData synchronize implicitly): no glFinish, which drained the
    // whole GPU pipeline mid-frame.
    d->api.gl_copy_buffer_sub_data(0x8F36, 0x8F37, (intptr_t)src_offset, (intptr_t)dst_offset, (intptr_t)size);
    return gl_result(d, diag, "glCopyBufferSubData");
}

struct ZenitGlTexture {
    ZenitGlDevice *device;
    uint32_t width, height, format, id, framebuffer;
};
/* Row zero is UI top throughout offscreen storage and transfers. Only native
 * presentation reverses Y. Packed staging accepts arbitrary byte row strides
 * without exposing padding, pixel pack buffers, or caller GL pixel-store state. */
typedef struct { int alignment, row_length, skip_rows, skip_pixels, buffer; } PixelState;
static void pixel_begin(ZenitGlDevice *d, int upload, PixelState *s) {
    uint32_t alignment = upload ? 0x0CF5 : 0x0D05;
    uint32_t row_length = upload ? 0x0CF2 : 0x0D02;
    uint32_t skip_rows = upload ? 0x0CF3 : 0x0D03;
    uint32_t skip_pixels = upload ? 0x0CF4 : 0x0D04;
    d->api.gl_get_integer(alignment, &s->alignment); d->api.gl_get_integer(row_length, &s->row_length);
    d->api.gl_get_integer(skip_rows, &s->skip_rows); d->api.gl_get_integer(skip_pixels, &s->skip_pixels);
    d->api.gl_get_integer(upload ? 0x88EF : 0x88ED, &s->buffer);
    d->api.gl_bind_buffer(upload ? 0x88EC : 0x88EB, 0);
    d->api.gl_pixel_store_i(alignment, 1); d->api.gl_pixel_store_i(row_length, 0);
    d->api.gl_pixel_store_i(skip_rows, 0); d->api.gl_pixel_store_i(skip_pixels, 0);
}
static void pixel_end(ZenitGlDevice *d, int upload, const PixelState *s) {
    d->api.gl_pixel_store_i(upload ? 0x0CF5 : 0x0D05, s->alignment);
    d->api.gl_pixel_store_i(upload ? 0x0CF2 : 0x0D02, s->row_length);
    d->api.gl_pixel_store_i(upload ? 0x0CF3 : 0x0D03, s->skip_rows);
    d->api.gl_pixel_store_i(upload ? 0x0CF4 : 0x0D04, s->skip_pixels);
    d->api.gl_bind_buffer(upload ? 0x88EC : 0x88EB, (uint32_t)s->buffer);
}
static uint32_t texture_external_format(uint32_t format) { return format == 1 ? 0x1903 : format == 3 ? 0x80E1 : 0x1908; }
int zenit_gl_texture_create(ZenitGlDevice *d, uint32_t width, uint32_t height, uint32_t format, ZenitGlTexture **out, ZenitGlDiagnostic *diag) {
    if (out) *out = NULL;
    if (!out || !width || !height || width > INT_MAX || height > INT_MAX || format < 1 || format > 4)
        return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "texture_descriptor", 0);
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    int max_size = 0; d->api.gl_get_integer(0x0D33, &max_size);
    size_t bpp = format == 1 ? 1 : format == 4 ? 8 : 4;
    if (width > (uint32_t)max_size || height > (uint32_t)max_size || width > SIZE_MAX / bpp / height)
        return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "texture_extent", 0);
    ZenitGlTexture *t = calloc(1, sizeof(*t));
    void *zero = calloc((size_t)width * height, bpp);
    if (!t || !zero) { free(t); free(zero); return fail(diag, ZENIT_GL_OUT_OF_MEMORY, "texture_initial_zeroes", 0); }
    t->device = d; t->width = width; t->height = height; t->format = format;
    int previous_texture = 0, previous_draw = 0;
    d->api.gl_get_integer(0x8069, &previous_texture); d->api.gl_get_integer(0x8CA6, &previous_draw);
    PixelState pixel; pixel_begin(d, 1, &pixel);
    d->api.gl_gen_textures(1, &t->id);
    if (!t->id) { status = fail(diag, ZENIT_GL_API_FAILED, "glGenTextures", 0); goto restored; }
    d->api.gl_bind_texture(0x0DE1, t->id);
    d->api.gl_tex_storage_2d(0x0DE1, 1, format == 1 ? 0x8229 : format == 4 ? 0x881A : 0x8058, (int)width, (int)height);
    d->api.gl_tex_parameter_i(0x0DE1, 0x2801, 0x2601); d->api.gl_tex_parameter_i(0x0DE1, 0x2800, 0x2601);
    d->api.gl_tex_parameter_i(0x0DE1, 0x2802, 0x812F); d->api.gl_tex_parameter_i(0x0DE1, 0x2803, 0x812F);
    d->api.gl_tex_sub_image_2d(0x0DE1, 0, 0, 0, (int)width, (int)height, texture_external_format(format), format == 4 ? 0x140B : 0x1401, zero);
    status = gl_result(d, diag, "texture_storage_and_initialization"); if (status) goto restored;
    d->api.gl_gen_framebuffers(1, &t->framebuffer);
    if (!t->framebuffer) { status = fail(diag, ZENIT_GL_API_FAILED, "glGenFramebuffers", 0); goto restored; }
    d->api.gl_bind_framebuffer(0x8CA9, t->framebuffer);
    d->api.gl_framebuffer_texture_2d(0x8CA9, 0x8CE0, 0x0DE1, t->id, 0);
    uint32_t completeness = d->api.gl_check_framebuffer_status(0x8CA9);
    if (completeness != 0x8CD5) status = fail(diag, ZENIT_GL_API_FAILED, "texture_framebuffer_complete", completeness);
restored:
    d->api.gl_bind_texture(0x0DE1, (uint32_t)previous_texture);
    d->api.gl_bind_framebuffer(0x8CA9, (uint32_t)previous_draw);
    pixel_end(d, 1, &pixel); free(zero);
    if (!status) status = gl_result(d, diag, "texture_create");
    if (!status) status = zenit_gl_retain_resource(d, diag);
    if (status) {
        if (t->framebuffer) d->api.gl_delete_framebuffers(1, &t->framebuffer);
        if (t->id) d->api.gl_delete_textures(1, &t->id);
        free(t); return status;
    }
    *out = t; return ZENIT_GL_OK;
}
int zenit_gl_texture_destroy(ZenitGlTexture *t, ZenitGlDiagnostic *diag) {
    if (!t) return ZENIT_GL_OK;
    ZenitGlDevice *d = t->device;
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    d->api.gl_delete_framebuffers(1, &t->framebuffer); d->api.gl_delete_textures(1, &t->id);
    status = gl_result(d, diag, "texture_destroy"); if (status) return status;
    status = zenit_gl_release_resource(d, diag); if (status) return status;
    free(t); return ZENIT_GL_OK;
}
int zenit_gl_texture_clear(ZenitGlTexture *t, const float rgba[4], ZenitGlDiagnostic *diag) {
    if (!t || !rgba) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "texture_clear_color", 0);
    ZenitGlDevice *d = t->device;
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    int draw = 0, mask[4] = {0};
    d->api.gl_get_integer(0x8CA6, &draw); d->api.gl_get_integer(0x0C23, mask);
    unsigned char scissor = d->api.gl_is_enabled(0x0C11);
    d->api.gl_disable(0x0C11); d->api.gl_color_mask(1, 1, 1, 1);
    d->api.gl_bind_framebuffer(0x8CA9, t->framebuffer);
    d->api.gl_clear_buffer_fv(0x1800, 0, rgba);
    d->api.gl_bind_framebuffer(0x8CA9, (uint32_t)draw);
    d->api.gl_color_mask((unsigned char)mask[0], (unsigned char)mask[1], (unsigned char)mask[2], (unsigned char)mask[3]);
    if (scissor) d->api.gl_enable(0x0C11);
    return gl_result(d, diag, "texture_clear");
}
int zenit_gl_texture_transfer(ZenitGlTexture *t, uint32_t x, uint32_t y, uint32_t width, uint32_t height,
    uint8_t *bytes, size_t length, uint32_t stride, int upload, ZenitGlDiagnostic *diag) {
    if (!t || !bytes || !width || !height || (upload != 0 && upload != 1) || x > t->width || width > t->width - x || y > t->height || height > t->height - y)
        return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "texture_transfer_region", 0);
    size_t row = (size_t)width * (t->format == 1 ? 1 : t->format == 4 ? 8 : 4);
    if (stride < row || height - 1 > (SIZE_MAX - row) / stride || length < (size_t)(height - 1) * stride + row || height > SIZE_MAX / row)
        return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "texture_transfer_stride", 0);
    ZenitGlDevice *d = t->device;
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    uint8_t *packed = malloc(row * height);
    if (!packed) return fail(diag, ZENIT_GL_OUT_OF_MEMORY, "texture_transfer_staging", 0);
    if (upload) for (uint32_t i = 0; i < height; ++i) memcpy(packed + i * row, bytes + (size_t)i * stride, row);
    PixelState pixel; pixel_begin(d, upload, &pixel);
    int binding = 0;
    d->api.gl_get_integer(upload ? 0x8069 : 0x8CAA, &binding);
    if (upload) {
        d->api.gl_bind_texture(0x0DE1, t->id);
        d->api.gl_tex_sub_image_2d(0x0DE1, 0, (int)x, (int)y, (int)width, (int)height, texture_external_format(t->format), t->format == 4 ? 0x140B : 0x1401, packed);
        d->api.gl_bind_texture(0x0DE1, (uint32_t)binding);
    } else {
        d->api.gl_bind_framebuffer(0x8CA8, t->framebuffer);
        d->api.gl_read_pixels((int)x, (int)y, (int)width, (int)height, texture_external_format(t->format), t->format == 4 ? 0x140B : 0x1401, packed);
        d->api.gl_bind_framebuffer(0x8CA8, (uint32_t)binding);
    }
    pixel_end(d, upload, &pixel);
    status = gl_result(d, diag, upload ? "texture_upload" : "texture_readback");
    if (!status && !upload) for (uint32_t i = 0; i < height; ++i) memcpy(bytes + (size_t)i * stride, packed + i * row, row);
    free(packed); return status;
}
int zenit_gl_texture_copy(ZenitGlTexture *src, uint32_t x, uint32_t y, ZenitGlTexture *dst, uint32_t dx, uint32_t dy, uint32_t width, uint32_t height, ZenitGlDiagnostic *diag) {
    if (!src || !dst || src->device != dst->device || src->format != dst->format || !width || !height ||
        x > src->width || width > src->width - x || y > src->height || height > src->height - y ||
        dx > dst->width || width > dst->width - dx || dy > dst->height || height > dst->height - dy ||
        (src == dst && x < dx + width && dx < x + width && y < dy + height && dy < y + height))
        return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "texture_copy_region_or_device", 0);
    ZenitGlDevice *d = src->device;
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    // Same-context ordering covers later draws and glReadPixels; a glFinish here
    // stalled the frame once per backdrop/glass blit.
    d->api.gl_copy_image_sub_data(src->id, 0x0DE1, 0, (int)x, (int)y, 0, dst->id, 0x0DE1, 0, (int)dx, (int)dy, 0, (int)width, (int)height, 1);
    return gl_result(d, diag, "texture_copy");
}

struct ZenitGlSampler { ZenitGlDevice *device; uint32_t id; };
int zenit_gl_sampler_create_descriptor(ZenitGlDevice *d, const ZenitGlSamplerDescriptor *desc, ZenitGlSampler **out, ZenitGlDiagnostic *diag) {
    if (out) *out = NULL;
    if (!out || !desc || desc->mag_filter > 1 || desc->min_filter > 1 || desc->mipmap_filter > 1 ||
        desc->address_u > 3 || desc->address_v > 3 || desc->address_w > 3 ||
        !isfinite(desc->lod_min) || !isfinite(desc->lod_max) || desc->lod_min < 0 || desc->lod_max < desc->lod_min)
        return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "sampler_descriptor", 0);
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    ZenitGlSampler *s = calloc(1, sizeof(*s));
    if (!s) return fail(diag, ZENIT_GL_OUT_OF_MEMORY, "sampler_owner", 0);
    s->device = d; d->api.gl_gen_samplers(1, &s->id);
    if (!s->id) { free(s); return fail(diag, ZENIT_GL_API_FAILED, "glGenSamplers", 0); }
    const int addresses[] = {0x812F, 0x2901, 0x8370, 0x812D};
    const int min_filters[2][2] = {{0x2700, 0x2702}, {0x2701, 0x2703}};
    d->api.gl_sampler_parameter_i(s->id, 0x2800, desc->mag_filter ? 0x2601 : 0x2600);
    d->api.gl_sampler_parameter_i(s->id, 0x2801, min_filters[desc->min_filter][desc->mipmap_filter]);
    d->api.gl_sampler_parameter_i(s->id, 0x2802, addresses[desc->address_u]);
    d->api.gl_sampler_parameter_i(s->id, 0x2803, addresses[desc->address_v]);
    d->api.gl_sampler_parameter_i(s->id, 0x8072, addresses[desc->address_w]);
    d->api.gl_sampler_parameter_f(s->id, 0x813A, desc->lod_min); d->api.gl_sampler_parameter_f(s->id, 0x813B, desc->lod_max);
    const float border[4] = {0}; d->api.gl_sampler_parameter_fv(s->id, 0x1004, border);
    status = gl_result(d, diag, "sampler_parameters");
    if (!status) status = zenit_gl_retain_resource(d, diag);
    if (status) { d->api.gl_delete_samplers(1, &s->id); free(s); return status; }
    *out = s; return ZENIT_GL_OK;
}
int zenit_gl_sampler_destroy(ZenitGlSampler *s, ZenitGlDiagnostic *diag) {
    if (!s) return ZENIT_GL_OK;
    ZenitGlDevice *d = s->device;
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    d->api.gl_delete_samplers(1, &s->id);
    status = gl_result(d, diag, "sampler_destroy"); if (status) return status;
    status = zenit_gl_release_resource(d, diag); if (status) return status;
    free(s); return ZENIT_GL_OK;
}
struct ZenitGlFence { ZenitGlDevice *device; void *sync; int completed; };
int zenit_gl_fence_create(ZenitGlDevice *d, ZenitGlFence **out, ZenitGlDiagnostic *diag) {
    if (out) *out = NULL;
    if (!out) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "fence_output", 0);
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    ZenitGlFence *f = calloc(1, sizeof(*f));
    if (!f) return fail(diag, ZENIT_GL_OUT_OF_MEMORY, "fence_owner", 0);
    f->device = d; f->sync = d->api.gl_fence_sync(0x9117, 0);
    d->api.gl_flush();
    status = gl_result(d, diag, "glFenceSync");
    if (!status && !f->sync) status = fail(diag, ZENIT_GL_API_FAILED, "null_GLsync", 0);
    if (!status) status = zenit_gl_retain_resource(d, diag);
    if (status) { if (f->sync) d->api.gl_delete_sync(f->sync); free(f); return status; }
    *out = f; return ZENIT_GL_OK;
}
int zenit_gl_fence_wait(ZenitGlFence *f, uint64_t timeout_ns, uint32_t *completed, ZenitGlDiagnostic *diag) {
    if (completed) *completed = 0;
    if (!f || !completed) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "fence_wait_descriptor", 0);
    ZenitGlDevice *d = f->device;
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    if (f->completed) { *completed = 1; return ZENIT_GL_OK; }
    struct timespec wait_start, wait_end;
    clock_gettime(CLOCK_MONOTONIC, &wait_start);
    uint32_t result = d->api.gl_client_wait_sync(f->sync, 0, timeout_ns);
    clock_gettime(CLOCK_MONOTONIC, &wait_end);
    d->fence_wait_ns += (uint64_t)((int64_t)(wait_end.tv_sec - wait_start.tv_sec) * 1000000000LL + (wait_end.tv_nsec - wait_start.tv_nsec));
    if (result == 0x911B) return ZENIT_GL_OK; /* GL_TIMEOUT_EXPIRED */
    if (result != 0x911A && result != 0x911C) return fail(diag, ZENIT_GL_API_FAILED, "glClientWaitSync", result);
    status = gl_result(d, diag, "glClientWaitSync"); if (status) return status;
    f->completed = 1; *completed = 1; return ZENIT_GL_OK;
}
int zenit_gl_fence_retire(ZenitGlFence *f, uint64_t timeout_ns, uint32_t *completed, ZenitGlDiagnostic *diag) {
    if (!f) { if (completed) *completed = 1; return completed ? ZENIT_GL_OK : fail(diag, ZENIT_GL_INVALID_ARGUMENT, "fence_retire_output", 0); }
    int status = zenit_gl_fence_wait(f, timeout_ns, completed, diag);
    if (status || !*completed) return status;
    ZenitGlDevice *d = f->device;
    d->api.gl_delete_sync(f->sync);
    status = gl_result(d, diag, "glDeleteSync");
    if (status) { *completed = 0; return status; }
    status = zenit_gl_release_resource(d, diag); if (status) { *completed = 0; return status; }
    free(f); return ZENIT_GL_OK;
}
