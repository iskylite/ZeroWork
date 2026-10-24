/* Reusable graphics pipelines; descriptors are derived from the compiled
 * SPIR-V manifest, never inferred from HLSL text or entry-point names. */
struct ZenitVkPipeline {
    ZenitVkDevice *device;
    VkPipeline pipeline;
    VkPipelineLayout layout;
    VkRenderPass pass;
    VkDescriptorSetLayout groups[4];
    VkDescriptorSetLayoutBinding bindings[4][64];
    uint32_t counts[4], group_count, binding_count;
    VkFormat format;
};
void zenit_vk_pipeline_destroy(ZenitVkPipeline *p) {
    if (!p) return;
    ZenitVkDevice *d = p->device;
    if (p->pipeline) d->DestroyPipeline(d->device, p->pipeline, NULL);
    if (p->layout) d->DestroyPipelineLayout(d->device, p->layout, NULL);
    if (p->pass) d->DestroyRenderPass(d->device, p->pass, NULL);
    for (uint32_t i = 0; i < 4; ++i) if (p->groups[i]) d->DestroyDescriptorSetLayout(d->device, p->groups[i], NULL);
    --d->live_resources;
    free(p);
}
static int shader_code_valid(const ZenitVkShaderCode *shader) {
    return shader && shader->code && shader->entry && shader->entry[0] &&
        shader->length >= 20 && !(shader->length % 4) &&
        !((uintptr_t)shader->code % 4) && shader->code[0] == 0x07230203;
}
int zenit_vk_pipeline_create_configured(ZenitVkDevice *d, const ZenitVkShaderCode *vertex,
                             const ZenitVkShaderCode *fragment,
                             const ZenitVkPipelineBinding *bindings, uint32_t count,
                             const ZenitVkPipelineState *state, ZenitVkPipeline **out, ZenitVkDiagnostic *diag) {
    if (!state) return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "pipeline state", VK_SUCCESS);
    const uint32_t format = state->format;
    if (!d || !out || !shader_code_valid(vertex) || !shader_code_valid(fragment) ||
        format < 1 || format > 4 || state->blend_enabled > 1 ||
        state->source_rgb > 14 || state->destination_rgb > 14 || state->source_alpha > 14 ||
        state->destination_alpha > 14 || state->rgb_operation > 4 || state->alpha_operation > 4 || count > 64 || (count && !bindings))
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "pipeline descriptor", VK_SUCCESS);
    *out = NULL;
    VkDescriptorSetLayoutBinding entries[4][64] = {0};
    uint32_t counts[4] = {0}, group_count = 0;
    for (uint32_t i = 0; i < count; ++i) {
        const ZenitVkPipelineBinding *b = &bindings[i];
        if (b->group >= 4 || !b->stages || (b->stages & ~3u))
            return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "pipeline binding group/stages", VK_SUCCESS);
        VkDescriptorType type;
        switch (b->kind) {
        case 0: type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER; break;
        case 1: type = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE; break;
        case 2: type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; break;
        case 4: type = VK_DESCRIPTOR_TYPE_SAMPLER; break;
        default: return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "pipeline binding kind", VK_SUCCESS);
        }
        VkShaderStageFlags stages = (b->stages & 1 ? VK_SHADER_STAGE_VERTEX_BIT : 0) |
            (b->stages & 2 ? VK_SHADER_STAGE_FRAGMENT_BIT : 0);
        int found = 0;
        for (uint32_t j = 0; j < counts[b->group]; ++j) if (entries[b->group][j].binding == b->binding) {
            if (entries[b->group][j].descriptorType != type)
                return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "conflicting pipeline binding", VK_SUCCESS);
            entries[b->group][j].stageFlags |= stages; found = 1; break;
        }
        if (!found) entries[b->group][counts[b->group]++] = (VkDescriptorSetLayoutBinding){
            .binding = b->binding, .descriptorType = type, .descriptorCount = 1, .stageFlags = stages };
        if (b->group + 1 > group_count) group_count = b->group + 1;
    }
    ZenitVkPipeline *p = calloc(1, sizeof(*p));
    if (!p) return diagnostic(diag, ZENIT_VK_OUT_OF_MEMORY, "allocate pipeline owner", VK_ERROR_OUT_OF_HOST_MEMORY);
    p->device = d; ++d->live_resources;
    memcpy(p->bindings, entries, sizeof(entries));
    memcpy(p->counts, counts, sizeof(counts));
    p->group_count = group_count;
    for (uint32_t i = 0; i < 4; ++i) p->binding_count += counts[i];
    VkShaderModule shaders[2] = {0};
    VkResult result;
    const char *operation = "pipeline creation";
#define PIPE_CHECK(name, call) do { operation = name; result = (call); if (result != VK_SUCCESS) goto cleanup; } while (0)
    for (uint32_t i = 0; i < group_count; ++i) {
        VkDescriptorSetLayoutCreateInfo info = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = counts[i], .pBindings = entries[i] };
        PIPE_CHECK("vkCreateDescriptorSetLayout", d->CreateDescriptorSetLayout(d->device, &info, NULL, &p->groups[i]));
    }
    VkPipelineLayoutCreateInfo layout = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = group_count, .pSetLayouts = p->groups };
    PIPE_CHECK("vkCreatePipelineLayout", d->CreatePipelineLayout(d->device, &layout, NULL, &p->layout));
    VkFormat target = format == 1 ? VK_FORMAT_R8_UNORM : format == 2 ? VK_FORMAT_R8G8B8A8_UNORM : format == 4 ? VK_FORMAT_R16G16B16A16_SFLOAT : VK_FORMAT_B8G8R8A8_UNORM;
    p->format = target;
    VkAttachmentDescription attachment = { .format = target, .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_LOAD, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkAttachmentReference reference = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription subpass = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1, .pColorAttachments = &reference };
    VkRenderPassCreateInfo pass = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1, .pAttachments = &attachment, .subpassCount = 1, .pSubpasses = &subpass };
    PIPE_CHECK("vkCreateRenderPass(pipeline)", d->CreateRenderPass(d->device, &pass, NULL, &p->pass));
    const ZenitVkShaderCode *codes[2] = {vertex, fragment};
    for (uint32_t i = 0; i < 2; ++i) {
        VkShaderModuleCreateInfo shader = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = codes[i]->length, .pCode = codes[i]->code };
        PIPE_CHECK("vkCreateShaderModule(UI)", d->CreateShaderModule(d->device, &shader, NULL, &shaders[i]));
    }
    VkPipelineShaderStageCreateInfo stages[2] = {
        { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
          .module = shaders[0], .pName = vertex->entry },
        { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
          .module = shaders[1], .pName = fragment->entry } };
    VkPipelineVertexInputStateCreateInfo input = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    VkPipelineInputAssemblyStateCreateInfo assembly = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
    VkPipelineViewportStateCreateInfo viewport = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1, .scissorCount = 1 };
    VkDynamicState states[] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dynamic = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = 2, .pDynamicStates = states };
    VkPipelineRasterizationStateCreateInfo raster = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1.0f };
    VkPipelineMultisampleStateCreateInfo multisample = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
    static const VkBlendFactor factors[] = {
        VK_BLEND_FACTOR_ZERO, VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_SRC_COLOR, VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR,
        VK_BLEND_FACTOR_SRC_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, VK_BLEND_FACTOR_DST_COLOR, VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR,
        VK_BLEND_FACTOR_DST_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA, VK_BLEND_FACTOR_SRC_ALPHA_SATURATE,
        VK_BLEND_FACTOR_CONSTANT_COLOR, VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR,
        VK_BLEND_FACTOR_CONSTANT_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA };
    static const VkBlendOp operations[] = { VK_BLEND_OP_ADD, VK_BLEND_OP_SUBTRACT, VK_BLEND_OP_REVERSE_SUBTRACT, VK_BLEND_OP_MIN, VK_BLEND_OP_MAX };
    VkPipelineColorBlendAttachmentState blend_attachment = { .blendEnable = state->blend_enabled,
        .srcColorBlendFactor = factors[state->source_rgb], .dstColorBlendFactor = factors[state->destination_rgb],
        .colorBlendOp = operations[state->rgb_operation], .srcAlphaBlendFactor = factors[state->source_alpha],
        .dstAlphaBlendFactor = factors[state->destination_alpha], .alphaBlendOp = operations[state->alpha_operation], .colorWriteMask = 15 };
    VkPipelineColorBlendStateCreateInfo blend = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1, .pAttachments = &blend_attachment };
    VkGraphicsPipelineCreateInfo pipeline = { .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2, .pStages = stages, .pVertexInputState = &input, .pInputAssemblyState = &assembly,
        .pViewportState = &viewport, .pRasterizationState = &raster, .pMultisampleState = &multisample,
        .pColorBlendState = &blend, .pDynamicState = &dynamic, .layout = p->layout, .renderPass = p->pass };
    PIPE_CHECK("vkCreateGraphicsPipelines(UI)", d->CreateGraphicsPipelines(d->device, VK_NULL_HANDLE, 1, &pipeline, NULL, &p->pipeline));
    *out = p;
cleanup:
    for (uint32_t i = 0; i < 2; ++i) if (shaders[i]) d->DestroyShaderModule(d->device, shaders[i], NULL);
    if (!*out) zenit_vk_pipeline_destroy(p);
#undef PIPE_CHECK
    return resource_result(diag, operation, result);
}

struct ZenitVkSampler { ZenitVkDevice *device; VkSampler sampler; };
void zenit_vk_sampler_destroy(ZenitVkSampler *s) {
    if (!s) return;
    s->device->DestroySampler(s->device->device, s->sampler, NULL);
    --s->device->live_resources;
    free(s);
}
int zenit_vk_sampler_create_descriptor(ZenitVkDevice *d, const ZenitVkSamplerDescriptor *desc,
                            ZenitVkSampler **out, ZenitVkDiagnostic *diag) {
    if (!d || !out || !desc || desc->mag_filter > 1 || desc->min_filter > 1 || desc->mipmap_filter > 1 ||
        desc->address_u > 3 || desc->address_v > 3 || desc->address_w > 3 ||
        !isfinite(desc->lod_min) || !isfinite(desc->lod_max) || desc->lod_min < 0 || desc->lod_max < desc->lod_min)
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "sampler descriptor", VK_SUCCESS);
    *out = NULL;
    ZenitVkSampler *s = calloc(1, sizeof(*s));
    if (!s) return diagnostic(diag, ZENIT_VK_OUT_OF_MEMORY, "allocate sampler owner", VK_ERROR_OUT_OF_HOST_MEMORY);
    s->device = d;
    const VkSamplerAddressMode addresses[] = {VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, VK_SAMPLER_ADDRESS_MODE_REPEAT,
        VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER};
    VkSamplerCreateInfo info = { .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = desc->mag_filter ? VK_FILTER_LINEAR : VK_FILTER_NEAREST,
        .minFilter = desc->min_filter ? VK_FILTER_LINEAR : VK_FILTER_NEAREST,
        .mipmapMode = desc->mipmap_filter ? VK_SAMPLER_MIPMAP_MODE_LINEAR : VK_SAMPLER_MIPMAP_MODE_NEAREST,
        .addressModeU = addresses[desc->address_u], .addressModeV = addresses[desc->address_v], .addressModeW = addresses[desc->address_w],
        .minLod = desc->lod_min, .maxLod = desc->lod_max, .maxAnisotropy = 1,
        .borderColor = VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK };
    VkResult result = d->CreateSampler(d->device, &info, NULL, &s->sampler);
    if (result != VK_SUCCESS) { free(s); return resource_result(diag, "vkCreateSampler", result); }
    ++d->live_resources; *out = s;
    return ZENIT_VK_OK;
}
int zenit_vk_sampler_create(ZenitVkDevice *d, int linear, int repeat,
                            ZenitVkSampler **out, ZenitVkDiagnostic *diag) {
    const ZenitVkSamplerDescriptor desc = {.mag_filter = !!linear, .min_filter = !!linear,
        .address_u = !!repeat, .address_v = !!repeat, .address_w = !!repeat};
    return zenit_vk_sampler_create_descriptor(d, &desc, out, diag);
}

static void draw_image_barrier(ZenitVkTexture *t, VkCommandBuffer command, VkImageLayout next) {
    VkImageMemoryBarrier barrier = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = t->layout == VK_IMAGE_LAYOUT_UNDEFINED ? 0 : VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
        .dstAccessMask = next == VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL ?
            VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT : VK_ACCESS_SHADER_READ_BIT,
        .oldLayout = t->layout, .newLayout = next,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = t->image, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    t->device->CmdPipelineBarrier(command, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
}

int zenit_vk_pipeline_draw_region(ZenitVkPipeline *p, ZenitVkTexture *target,
                           const ZenitVkDrawBinding *bindings, uint32_t count,
                           uint32_t first_vertex, uint32_t vertices,
                           uint32_t first_instance, uint32_t instances,
                           const float *clear, const ZenitVkDrawRegion *region, ZenitVkDiagnostic *diag) {
    if (!p || !target || p->device != target->device || p->format != target->format ||
        !vertices || !instances || count != p->binding_count || count > 64 ||
        (count && !bindings) || (!clear && target->layout == VK_IMAGE_LAYOUT_UNDEFINED))
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "draw descriptor/target", VK_SUCCESS);
    ZenitVkDevice *d = p->device;
    if (region) {
        const float *v = region->viewport;
        const uint32_t *s = region->scissor;
        for (uint32_t i = 0; i < 6; ++i) if (!isfinite(v[i]))
            return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "nonfinite viewport", VK_SUCCESS);
        if (v[2] <= 0 || v[3] <= 0 || v[2] > d->properties.limits.maxViewportDimensions[0] ||
            v[3] > d->properties.limits.maxViewportDimensions[1] || v[4] < 0 || v[5] > 1 || v[4] > v[5] ||
            v[0] < d->properties.limits.viewportBoundsRange[0] || v[1] < d->properties.limits.viewportBoundsRange[0] ||
            v[0] + v[2] > d->properties.limits.viewportBoundsRange[1] || v[1] + v[3] > d->properties.limits.viewportBoundsRange[1] ||
            s[0] > INT32_MAX || s[1] > INT32_MAX || s[2] > INT32_MAX - s[0] || s[3] > INT32_MAX - s[1])
            return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "viewport/scissor range", VK_SUCCESS);
    }
    VkDescriptorBufferInfo buffers[64];
    VkDescriptorImageInfo images[64];
    VkWriteDescriptorSet writes[64];
    VkDescriptorPoolSize sizes[4] = {
        {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 0}, {VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 0},
        {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 0}, {VK_DESCRIPTOR_TYPE_SAMPLER, 0} };
    for (uint32_t i = 0; i < count; ++i) {
        const ZenitVkDrawBinding *b = &bindings[i];
        if (b->group >= p->group_count || !b->resource || (b->kind != 0 && b->kind != 1 && b->kind != 2 && b->kind != 4))
            return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "draw resource/group", VK_SUCCESS);
        for (uint32_t j = 0; j < i; ++j) if (bindings[j].group == b->group && bindings[j].binding == b->binding)
            return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "duplicate draw binding", VK_SUCCESS);
        const VkDescriptorSetLayoutBinding *entry = NULL;
        for (uint32_t j = 0; j < p->counts[b->group]; ++j) if (p->bindings[b->group][j].binding == b->binding) {
            entry = &p->bindings[b->group][j]; break;
        }
        uint32_t index = b->kind == 4 ? 3 : b->kind;
        if (!entry || index >= 4 || entry->descriptorType != sizes[index].type)
            return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "draw binding kind", VK_SUCCESS);
        ++sizes[index].descriptorCount;
        writes[i] = (VkWriteDescriptorSet){ .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstBinding = b->binding, .descriptorCount = 1, .descriptorType = entry->descriptorType };
        if (b->kind == 0 || b->kind == 2) {
            ZenitVkBuffer *buffer = b->resource;
            uint64_t alignment = b->kind == 0 ? d->properties.limits.minUniformBufferOffsetAlignment : d->properties.limits.minStorageBufferOffsetAlignment;
            uint64_t limit = b->kind == 0 ? d->properties.limits.maxUniformBufferRange : d->properties.limits.maxStorageBufferRange;
            if (buffer->device != d || !(buffer->usage & (1u << (b->kind == 0 ? 6 : 7))) ||
                !b->size || b->size > limit || b->offset > buffer->size || b->size > buffer->size - b->offset ||
                (alignment && b->offset % alignment))
                return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "draw buffer range/alignment/usage", VK_SUCCESS);
            buffers[i] = (VkDescriptorBufferInfo){ buffer->buffer, b->offset, b->size };
            writes[i].pBufferInfo = &buffers[i];
        } else if (b->kind == 1) {
            ZenitVkTexture *texture = b->resource;
            if (texture->device != d || texture == target || texture->layout == VK_IMAGE_LAYOUT_UNDEFINED)
                return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "draw sampled texture", VK_SUCCESS);
            images[i] = (VkDescriptorImageInfo){ .imageView = texture->view, .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
            writes[i].pImageInfo = &images[i];
        } else {
            ZenitVkSampler *sampler = b->resource;
            if (sampler->device != d) return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "draw sampler device", VK_SUCCESS);
            images[i] = (VkDescriptorImageInfo){ .sampler = sampler->sampler };
            writes[i].pImageInfo = &images[i];
        }
    }
    VkDescriptorPool pool = VK_NULL_HANDLE;
    VkDescriptorSet sets[4] = {0};
    VkRenderPass pass = VK_NULL_HANDLE;
    VkFramebuffer framebuffer = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE;
    VkResult result;
    int status = ZENIT_VK_OK;
#define DRAW_CHECK(name, call) do { result = (call); if (result != VK_SUCCESS) { status = resource_result(diag, name, result); goto cleanup; } } while (0)
    if (count) {
        VkDescriptorPoolSize compact[4]; uint32_t size_count = 0;
        for (uint32_t i = 0; i < 4; ++i) if (sizes[i].descriptorCount) compact[size_count++] = sizes[i];
        VkDescriptorPoolCreateInfo info = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = p->group_count, .poolSizeCount = size_count, .pPoolSizes = compact };
        DRAW_CHECK("vkCreateDescriptorPool(draw)", d->CreateDescriptorPool(d->device, &info, NULL, &pool));
        VkDescriptorSetAllocateInfo alloc = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = pool, .descriptorSetCount = p->group_count, .pSetLayouts = p->groups };
        DRAW_CHECK("vkAllocateDescriptorSets(draw)", d->AllocateDescriptorSets(d->device, &alloc, sets));
        for (uint32_t i = 0; i < count; ++i) writes[i].dstSet = sets[bindings[i].group];
        d->UpdateDescriptorSets(d->device, count, writes, 0, NULL);
    }
    VkAttachmentDescription attachment = { .format = p->format, .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = clear ? VK_ATTACHMENT_LOAD_OP_CLEAR : VK_ATTACHMENT_LOAD_OP_LOAD,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE, .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkAttachmentReference reference = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription subpass = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1, .pColorAttachments = &reference };
    VkRenderPassCreateInfo pass_info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1, .pAttachments = &attachment, .subpassCount = 1, .pSubpasses = &subpass };
    DRAW_CHECK("vkCreateRenderPass(draw)", d->CreateRenderPass(d->device, &pass_info, NULL, &pass));
    VkFramebufferCreateInfo fb = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = pass, .attachmentCount = 1, .pAttachments = &target->view,
        .width = target->width, .height = target->height, .layers = 1 };
    DRAW_CHECK("vkCreateFramebuffer(draw)", d->CreateFramebuffer(d->device, &fb, NULL, &framebuffer));
    status = transfer_begin(d, &command, diag);
    if (status) goto cleanup;
    VkMemoryBarrier host_barrier = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_HOST_WRITE_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_UNIFORM_READ_BIT | VK_ACCESS_SHADER_READ_BIT };
    d->CmdPipelineBarrier(command, VK_PIPELINE_STAGE_HOST_BIT | VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT, 0, 1, &host_barrier, 0, NULL, 0, NULL);
    /* Each unique sampled image is transitioned once, even if bound twice. */
    for (uint32_t i = 0; i < count; ++i) if (bindings[i].kind == 1) {
        int duplicate = 0;
        for (uint32_t j = 0; j < i; ++j) if (bindings[j].kind == 1 && bindings[j].resource == bindings[i].resource) duplicate = 1;
        if (!duplicate) draw_image_barrier(bindings[i].resource, command, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    }
    draw_image_barrier(target, command, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
    VkClearValue value = {0};
    if (clear) memcpy(value.color.float32, clear, 4 * sizeof(float));
    VkRenderPassBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = pass, .framebuffer = framebuffer, .renderArea = { {0, 0}, {target->width, target->height} },
        .clearValueCount = clear ? 1 : 0, .pClearValues = &value };
    d->CmdBeginRenderPass(command, &begin, VK_SUBPASS_CONTENTS_INLINE);
    VkViewport viewport = {0, 0, (float)target->width, (float)target->height, 0, 1};
    VkRect2D scissor = {{0, 0}, {target->width, target->height}};
    if (region) {
        memcpy(&viewport, region->viewport, sizeof(viewport));
        scissor = (VkRect2D){ { (int32_t)region->scissor[0], (int32_t)region->scissor[1] },
            { region->scissor[2], region->scissor[3] } };
    }
    d->CmdSetViewport(command, 0, 1, &viewport); d->CmdSetScissor(command, 0, 1, &scissor);
    d->CmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, p->pipeline);
    if (count) d->CmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_GRAPHICS, p->layout, 0, p->group_count, sets, 0, NULL);
    d->CmdDraw(command, vertices, instances, first_vertex, first_instance);
    d->CmdEndRenderPass(command);
    status = transfer_finish(d, command, diag); command = VK_NULL_HANDLE;
    if (!status) {
        target->layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        for (uint32_t i = 0; i < count; ++i) if (bindings[i].kind == 1)
            ((ZenitVkTexture *)bindings[i].resource)->layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    }
cleanup:
    if (command) d->FreeCommandBuffers(d->device, d->pool, 1, &command);
    if (framebuffer) d->DestroyFramebuffer(d->device, framebuffer, NULL);
    if (pass) d->DestroyRenderPass(d->device, pass, NULL);
    if (pool) d->DestroyDescriptorPool(d->device, pool, NULL);
#undef DRAW_CHECK
    return status;
}

int zenit_vk_pipeline_create(ZenitVkDevice *d, const ZenitVkShaderCode *vertex,
    const ZenitVkShaderCode *fragment, const ZenitVkPipelineBinding *bindings, uint32_t count,
    uint32_t format, ZenitVkPipeline **out, ZenitVkDiagnostic *diag) {
    ZenitVkPipelineState state = { .format = format, .blend_enabled = 1,
        .source_rgb = 1, .destination_rgb = 5, .source_alpha = 1, .destination_alpha = 5 };
    return zenit_vk_pipeline_create_configured(d, vertex, fragment, bindings, count, &state, out, diag);
}
int zenit_vk_pipeline_draw(ZenitVkPipeline *p, ZenitVkTexture *target,
    const ZenitVkDrawBinding *bindings, uint32_t count, uint32_t first_vertex, uint32_t vertices,
    uint32_t first_instance, uint32_t instances, const float *clear, ZenitVkDiagnostic *diag) {
    return zenit_vk_pipeline_draw_region(p, target, bindings, count, first_vertex, vertices,
        first_instance, instances, clear, NULL, diag);
}
