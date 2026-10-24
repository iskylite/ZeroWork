/* Configured GL pipelines use the offline shader inventory's bindings and
 * explicit combined image/sampler mappings. GL buffer namespaces are distinct;
 * the current UI shader ABI uses descriptor group zero for all buffer blocks. */
struct ZenitGlPipeline {
    ZenitGlDevice *device;
    uint32_t program, vao, count, unit_count;
    ZenitGlPipelineBinding bindings[64];
    ZenitGlTextureUnit units[32]; /* uniform names are used only during creation */
    ZenitGlPipelineState state;
    int first_instance;
};
static const ZenitGlPipelineBinding *pipeline_binding(const ZenitGlPipelineBinding *bindings,
    uint32_t count, uint32_t group, uint32_t binding) {
    for (uint32_t i = 0; i < count; ++i) if (bindings[i].group == group && bindings[i].binding == binding) return &bindings[i];
    return NULL;
}
static const ZenitGlDrawBinding *draw_binding(const ZenitGlDrawBinding *bindings,
    uint32_t count, uint32_t group, uint32_t binding) {
    for (uint32_t i = 0; i < count; ++i) if (bindings[i].group == group && bindings[i].binding == binding) return &bindings[i];
    return NULL;
}
static int shader_compile(ZenitGlDevice *d, const ZenitGlShaderCode *code, uint32_t stage,
    uint32_t *out, ZenitGlDiagnostic *diag) {
    *out = d->api.gl_create_shader(stage);
    if (!*out) return fail(diag, ZENIT_GL_API_FAILED, "glCreateShader", 0);
    int length = (int)code->length, compiled = 0;
    d->api.gl_shader_source(*out, 1, &code->code, &length); d->api.gl_compile_shader(*out);
    d->api.gl_get_shader_iv(*out, 0x8B81, &compiled);
    if (!compiled) {
        char log[2048] = {0}; d->api.gl_get_shader_info_log(*out, sizeof(log), NULL, log);
        fprintf(stderr, "OPENGL_SHADER: %s\n", log);
        return fail(diag, ZENIT_GL_API_FAILED, "glCompileShader", stage);
    }
    return gl_result(d, diag, "glCompileShader");
}
int zenit_gl_pipeline_create_configured(ZenitGlDevice *d, const ZenitGlShaderCode *vertex,
    const ZenitGlShaderCode *fragment, const ZenitGlPipelineBinding *bindings, uint32_t count,
    const ZenitGlTextureUnit *units, uint32_t unit_count, const ZenitGlPipelineState *state,
    ZenitGlPipeline **out, ZenitGlDiagnostic *diag) {
    if (out) *out = NULL;
    if (!out || !vertex || !fragment || !vertex->code || !fragment->code ||
        !vertex->length || !fragment->length || vertex->length > INT_MAX || fragment->length > INT_MAX ||
        !state || state->format < 1 || state->format > 4 || state->blend_enabled > 1 ||
        state->source_rgb > 14 || state->destination_rgb > 14 || state->source_alpha > 14 || state->destination_alpha > 14 ||
        state->rgb_operation > 4 || state->alpha_operation > 4 || count > 64 || (count && !bindings) ||
        unit_count > 32 || (unit_count && !units))
        return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "pipeline_descriptor", 0);
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    int uniforms = 0, storage = 0, textures = 0;
    d->api.gl_get_integer(0x8A2F, &uniforms); d->api.gl_get_integer(0x90DD, &storage);
    d->api.gl_get_integer(0x8872, &textures);
    for (uint32_t i = 0; i < count; ++i) {
        const ZenitGlPipelineBinding *b = &bindings[i];
        if (b->group >= 4 || b->binding >= 64 || !b->stages || (b->stages & ~3u) ||
            (b->kind != 0 && b->kind != 1 && b->kind != 2 && b->kind != 4) ||
            ((b->kind == 0 || b->kind == 2) && (b->group || b->binding >= (uint32_t)(b->kind == 0 ? uniforms : storage))) ||
            pipeline_binding(bindings, i, b->group, b->binding))
            return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "pipeline_binding_contract", 0);
    }
    for (uint32_t i = 0; i < unit_count; ++i) {
        const ZenitGlTextureUnit *u = &units[i];
        const ZenitGlPipelineBinding *texture = pipeline_binding(bindings, count, u->texture_group, u->texture_binding);
        const ZenitGlPipelineBinding *sampler = pipeline_binding(bindings, count, u->sampler_group, u->sampler_binding);
        if (u->unit >= (uint32_t)textures || !u->uniform_name || !u->uniform_name[0] || !texture || texture->kind != 1 ||
            (u->sampler_group == UINT32_MAX ? u->sampler_binding != UINT32_MAX : !sampler || sampler->kind != 4))
            return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "pipeline_combined_sampler", 0);
        for (uint32_t j = 0; j < i; ++j) if (units[j].unit == u->unit || !strcmp(units[j].uniform_name, u->uniform_name))
            return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "duplicate_combined_sampler", 0);
    }
    ZenitGlPipeline *p = calloc(1, sizeof(*p));
    if (!p) return fail(diag, ZENIT_GL_OUT_OF_MEMORY, "pipeline_owner", 0);
    p->device = d; p->state = *state; p->count = count; p->unit_count = unit_count;
    if (count) memcpy(p->bindings, bindings, count * sizeof(*bindings));
    if (unit_count) memcpy(p->units, units, unit_count * sizeof(*units));
    uint32_t shaders[2] = {0};
    status = shader_compile(d, vertex, 0x8B31, &shaders[0], diag); if (status) goto cleanup;
    status = shader_compile(d, fragment, 0x8B30, &shaders[1], diag); if (status) goto cleanup;
    p->program = d->api.gl_create_program();
    if (!p->program) { status = fail(diag, ZENIT_GL_API_FAILED, "glCreateProgram", 0); goto cleanup; }
    d->api.gl_attach_shader(p->program, shaders[0]); d->api.gl_attach_shader(p->program, shaders[1]);
    d->api.gl_link_program(p->program);
    int linked = 0; d->api.gl_get_program_iv(p->program, 0x8B82, &linked);
    if (!linked) {
        char log[2048] = {0}; d->api.gl_get_program_info_log(p->program, sizeof(log), NULL, log);
        fprintf(stderr, "OPENGL_LINK: %s\n", log);
        status = fail(diag, ZENIT_GL_API_FAILED, "glLinkProgram", 0); goto cleanup;
    }
    p->first_instance = d->api.gl_get_uniform_location(p->program, "zenit_first_instance");
    for (uint32_t i = 0; i < unit_count; ++i) {
        int location = d->api.gl_get_uniform_location(p->program, units[i].uniform_name);
        if (location >= 0) d->api.gl_program_uniform_1i(p->program, location, (int)units[i].unit);
        p->units[i].uniform_name = NULL; /* caller metadata is not retained */
    }
    d->api.gl_gen_vertex_arrays(1, &p->vao);
    status = gl_result(d, diag, "pipeline_link_and_objects");
    if (!status && !p->vao) status = fail(diag, ZENIT_GL_API_FAILED, "glGenVertexArrays", 0);
    if (!status) status = zenit_gl_retain_resource(d, diag);
cleanup:
    for (uint32_t i = 0; i < 2; ++i) if (shaders[i]) d->api.gl_delete_shader(shaders[i]);
    if (status) {
        if (p->vao) d->api.gl_delete_vertex_arrays(1, &p->vao);
        if (p->program) d->api.gl_delete_program(p->program);
        free(p); return status;
    }
    *out = p; return ZENIT_GL_OK;
}
int zenit_gl_pipeline_destroy(ZenitGlPipeline *p, ZenitGlDiagnostic *diag) {
    if (!p) return ZENIT_GL_OK;
    ZenitGlDevice *d = p->device;
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    /* Retire any current program binding, so GL deletion is not deferred by
     * native state beyond this owner's retirement. */
    int active = 0; d->api.gl_get_integer(0x8B8D, &active);
    if ((uint32_t)active == p->program) d->api.gl_use_program(0);
    d->api.gl_delete_vertex_arrays(1, &p->vao); d->api.gl_delete_program(p->program);
    status = gl_result(d, diag, "pipeline_destroy"); if (status) return status;
    status = zenit_gl_release_resource(d, diag); if (status) return status;
    free(p); return ZENIT_GL_OK;
}
static const uint32_t blend_factors[] = {
    0, 1, 0x0300, 0x0301, 0x0302, 0x0303, 0x0306, 0x0307, 0x0304, 0x0305,
    0x0308, 0x8001, 0x8002, 0x8003, 0x8004
};
static const uint32_t blend_operations[] = {0x8006, 0x800A, 0x800B, 0x8007, 0x8008};
int zenit_gl_pipeline_draw_region(ZenitGlPipeline *p, ZenitGlTexture *target,
    const ZenitGlDrawBinding *bindings, uint32_t count, uint32_t first_vertex, uint32_t vertices,
    uint32_t first_instance, uint32_t instances, const float *clear, const ZenitGlDrawRegion *region, ZenitGlDiagnostic *diag) {
    if (!p || !target || target->device != p->device || target->format != p->state.format || count != p->count ||
        (count && !bindings) || !vertices || !instances || first_vertex > INT_MAX || vertices > INT_MAX - first_vertex ||
        first_instance > INT_MAX || instances > INT_MAX - first_instance)
        return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "draw_descriptor", 0);
    ZenitGlDevice *d = p->device;
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    float viewport[6] = {0, 0, (float)target->width, (float)target->height, 0, 1};
    uint32_t scissor[4] = {0, 0, target->width, target->height};
    if (region) { memcpy(viewport, region->viewport, sizeof(viewport)); memcpy(scissor, region->scissor, sizeof(scissor)); }
    if (!d->max_viewport[0]) d->api.gl_get_integer(0x0D3A, d->max_viewport);
    const int *max_viewport = d->max_viewport;
    for (uint32_t i = 0; i < 6; ++i) if (!isfinite(viewport[i])) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "nonfinite_viewport", 0);
    if (viewport[2] <= 0 || viewport[3] <= 0 || viewport[2] > max_viewport[0] || viewport[3] > max_viewport[1] ||
        viewport[0] < -32768 || viewport[1] < -32768 || viewport[0] + viewport[2] > 32767 || viewport[1] + viewport[3] > 32767 ||
        viewport[4] < 0 || viewport[5] > 1 || viewport[4] > viewport[5] ||
        scissor[0] > INT_MAX || scissor[1] > INT_MAX || scissor[2] > INT_MAX - scissor[0] || scissor[3] > INT_MAX - scissor[1])
        return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "viewport_scissor_range", 0);
    if (!d->uniform_alignment) d->api.gl_get_integer(0x8A34, &d->uniform_alignment);
    if (!d->storage_alignment) d->api.gl_get_integer(0x90DF, &d->storage_alignment);
    if (!d->uniform_limit) d->api.gl_get_integer(0x8A30, &d->uniform_limit);
    if (!d->storage_limit) d->api.gl_get_integer(0x90DE, &d->storage_limit);
    for (uint32_t i = 0; i < count; ++i) {
        const ZenitGlDrawBinding *b = &bindings[i];
        const ZenitGlPipelineBinding *entry = pipeline_binding(p->bindings, count, b->group, b->binding);
        if (!b->resource || !entry || entry->kind != b->kind || draw_binding(bindings, i, b->group, b->binding))
            return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "draw_binding_contract", 0);
        if (b->kind == 0 || b->kind == 2) {
            ZenitGlBuffer *buffer = b->resource;
            uint32_t alignment = (uint32_t)(b->kind == 0 ? d->uniform_alignment : d->storage_alignment);
            uint32_t limit = (uint32_t)(b->kind == 0 ? d->uniform_limit : d->storage_limit);
            if (buffer->device != d || !(buffer->usage & (1u << (b->kind == 0 ? 6 : 7))) ||
                !b->size || b->size > limit || b->offset > buffer->size || b->size > buffer->size - b->offset ||
                (alignment && b->offset % alignment))
                return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "draw_buffer_range_usage_alignment", 0);
        } else if (b->kind == 1) {
            ZenitGlTexture *texture = b->resource;
            if (texture->device != d || texture == target) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "draw_texture_device_feedback", 0);
        } else {
            ZenitGlSampler *sampler = b->resource;
            if (sampler->device != d) return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "draw_sampler_device", 0);
        }
    }
    if (clear) { status = zenit_gl_texture_clear(target, clear, diag); if (status) return status; }
    d->api.gl_bind_framebuffer(0x8CA9, target->framebuffer); d->api.gl_use_program(p->program);
    d->api.gl_bind_vertex_array(p->vao);
    d->api.gl_disable(0x8DB9); /* framebuffer SRGB: match encoded-color UI blending */
    d->api.gl_disable(0x0B71); d->api.gl_disable(0x0B90); d->api.gl_disable(0x0B44);
    d->api.gl_disable(0x8C89); d->api.gl_disable(0x0BD0); d->api.gl_disable(0x809D);
    d->api.gl_polygon_mode(0x0408, 0x1B02); d->api.gl_color_mask(1, 1, 1, 1);
    if (p->state.blend_enabled) d->api.gl_enable(0x0BE2); else d->api.gl_disable(0x0BE2);
    d->api.gl_blend_func_separate(blend_factors[p->state.source_rgb], blend_factors[p->state.destination_rgb],
        blend_factors[p->state.source_alpha], blend_factors[p->state.destination_alpha]);
    d->api.gl_blend_equation_separate(blend_operations[p->state.rgb_operation], blend_operations[p->state.alpha_operation]);
    d->api.gl_blend_color(0, 0, 0, 0);
    d->api.gl_viewport_indexed_f(0, viewport[0], viewport[1], viewport[2], viewport[3]);
    d->api.gl_depth_range_f(viewport[4], viewport[5]);
    d->api.gl_enable(0x0C11); d->api.gl_scissor((int)scissor[0], (int)scissor[1], (int)scissor[2], (int)scissor[3]);
    for (uint32_t i = 0; i < count; ++i) if (bindings[i].kind == 0 || bindings[i].kind == 2) {
        const ZenitGlDrawBinding *b = &bindings[i]; ZenitGlBuffer *buffer = b->resource;
        d->api.gl_bind_buffer_range(b->kind == 0 ? 0x8A11 : 0x90D2, b->binding, buffer->id, (intptr_t)b->offset, (intptr_t)b->size);
    }
    for (uint32_t i = 0; i < p->unit_count; ++i) {
        const ZenitGlTextureUnit *u = &p->units[i];
        const ZenitGlDrawBinding *image = draw_binding(bindings, count, u->texture_group, u->texture_binding);
        ZenitGlTexture *texture = image->resource;
        uint32_t sampler_id = 0;
        if (u->sampler_group != UINT32_MAX) {
            const ZenitGlDrawBinding *binding = draw_binding(bindings, count, u->sampler_group, u->sampler_binding);
            sampler_id = ((ZenitGlSampler *)binding->resource)->id;
        }
        d->api.gl_active_texture(0x84C0 + u->unit); d->api.gl_bind_texture(0x0DE1, texture->id);
        d->api.gl_bind_sampler(u->unit, sampler_id);
    }
    if (p->first_instance >= 0) d->api.gl_program_uniform_1i(p->program, p->first_instance, (int)first_instance);
    d->api.gl_draw_arrays_instanced(4, (int)first_vertex, (int)vertices, (int)instances);
    return gl_result(d, diag, "pipeline_draw");
}
int zenit_gl_present_texture(ZenitGlDevice *d, ZenitGlTexture *texture, uint32_t width, uint32_t height, ZenitGlDiagnostic *diag) {
    if (!texture || texture->device != d || (texture->format == 1 || texture->format == 4) || !width || !height || width > INT_MAX || height > INT_MAX)
        return fail(diag, ZENIT_GL_INVALID_ARGUMENT, "present_texture_descriptor", 0);
    int status = zenit_gl_make_current(d, diag); if (status) return status;
    status = zenit_gl_resize(d, width, height, diag); if (status) return status;
    d->api.gl_disable(0x0C11); d->api.gl_disable(0x8DB9);
    d->api.gl_bind_framebuffer(0x8CA8, texture->framebuffer); d->api.gl_bind_framebuffer(0x8CA9, 0);
    d->api.gl_blit_framebuffer(0, 0, (int)texture->width, (int)texture->height, 0, (int)height, (int)width, 0, 0x4000, 0x2600);
    status = gl_result(d, diag, "present_blit"); if (status) return status;
    /* Last request before eglSwapBuffers commits this extent: its viewport
     * destination is applied by that same commit. */
    zenit_gl_before_swap(d, width, height);
    return zenit_gl_present(d, diag);
}
