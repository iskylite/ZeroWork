/* Included after the device dispatch and memory-type selector. These are
 * reusable owned resources, independent of the diagnostic triangle probe. */
struct ZenitVkBuffer {
    ZenitVkDevice *device;
    VkBuffer buffer;
    VkDeviceMemory memory;
    VkDeviceSize size;
    uint32_t usage;
    void *mapped;
    int coherent;
};
struct ZenitVkTexture {
    ZenitVkDevice *device;
    VkImage image;
    VkDeviceMemory memory;
    VkImageView view;
    VkImageLayout layout;
    VkFormat format;
    uint32_t width, height, texel_size;
};

static int resource_result(ZenitVkDiagnostic *diag, const char *operation, VkResult result) {
    return diagnostic(diag, result == VK_SUCCESS ? ZENIT_VK_OK :
        (result == VK_ERROR_OUT_OF_HOST_MEMORY || result == VK_ERROR_OUT_OF_DEVICE_MEMORY ?
         ZENIT_VK_OUT_OF_MEMORY : ZENIT_VK_API_FAILED), operation, result);
}

void zenit_vk_buffer_destroy(ZenitVkBuffer *b) {
    if (!b) return;
    ZenitVkDevice *d = b->device;
    if (b->mapped) d->UnmapMemory(d->device, b->memory);
    if (b->buffer) d->DestroyBuffer(d->device, b->buffer, NULL);
    if (b->memory) d->FreeMemory(d->device, b->memory, NULL);
    --d->live_resources;
    free(b);
}

int zenit_vk_buffer_create(ZenitVkDevice *d, uint64_t size, uint32_t usage,
                           ZenitVkBuffer **out, ZenitVkDiagnostic *diag) {
    if (!d || !out || !size || size > SIZE_MAX || !usage || (usage & ~1023u))
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "buffer descriptor", VK_SUCCESS);
    *out = NULL;
    ZenitVkBuffer *b = calloc(1, sizeof(*b));
    if (!b) return diagnostic(diag, ZENIT_VK_OUT_OF_MEMORY, "allocate buffer owner", VK_ERROR_OUT_OF_HOST_MEMORY);
    b->device = d; b->size = size; b->usage = usage; ++d->live_resources;
    /* Initial resource implementation uses host-visible storage for buffers.
     * Queue completion is explicit, including noncoherent cache maintenance. */
    VkBufferUsageFlags flags = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    if (usage & (1u << 4)) flags |= VK_BUFFER_USAGE_INDEX_BUFFER_BIT;
    if (usage & (1u << 5)) flags |= VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
    if (usage & (1u << 6)) flags |= VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    if (usage & (1u << 7)) flags |= VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    if (usage & (1u << 8)) flags |= VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT;
    VkBufferCreateInfo info = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size, .usage = flags, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    VkResult result = d->CreateBuffer(d->device, &info, NULL, &b->buffer);
    const char *operation = "vkCreateBuffer";
    if (result != VK_SUCCESS) goto fail;
    VkMemoryRequirements req;
    d->GetBufferMemoryRequirements(d->device, b->buffer, &req);
    uint32_t type = memory_type(d, req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
        VK_MEMORY_PROPERTY_HOST_COHERENT_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT);
    if (type == UINT32_MAX) { zenit_vk_buffer_destroy(b); return diagnostic(diag, ZENIT_VK_NO_DEVICE, "host-visible buffer memory", VK_SUCCESS); }
    b->coherent = !!(d->memory.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VkMemoryAllocateInfo alloc = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size, .memoryTypeIndex = type };
    operation = "vkAllocateMemory(buffer)";
    result = d->AllocateMemory(d->device, &alloc, NULL, &b->memory);
    if (result != VK_SUCCESS) goto fail;
    operation = "vkBindBufferMemory";
    result = d->BindBufferMemory(d->device, b->buffer, b->memory, 0);
    if (result != VK_SUCCESS) goto fail;
    operation = "vkMapMemory(buffer)";
    result = d->MapMemory(d->device, b->memory, 0, VK_WHOLE_SIZE, 0, &b->mapped);
    if (result != VK_SUCCESS) goto fail;
    *out = b;
    return ZENIT_VK_OK;
fail:
    zenit_vk_buffer_destroy(b);
    return resource_result(diag, operation, result);
}

static int buffer_range(ZenitVkBuffer *b, uint64_t offset, const void *bytes, size_t length,
                         ZenitVkDiagnostic *diag) {
    if (!b || !bytes || !length || offset > b->size || length > b->size - offset)
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "buffer transfer range", VK_SUCCESS);
    return ZENIT_VK_OK;
}
int zenit_vk_buffer_write(ZenitVkBuffer *b, uint64_t offset, const uint8_t *bytes,
                          size_t length, ZenitVkDiagnostic *diag) {
    int status = buffer_range(b, offset, bytes, length, diag);
    if (status) return status;
    memcpy((uint8_t *)b->mapped + offset, bytes, length);
    if (b->coherent) return ZENIT_VK_OK;
    VkMappedMemoryRange range = { .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
        .memory = b->memory, .offset = 0, .size = VK_WHOLE_SIZE };
    return resource_result(diag, "vkFlushMappedMemoryRanges", b->device->FlushMappedMemoryRanges(b->device->device, 1, &range));
}
int zenit_vk_buffer_read(ZenitVkBuffer *b, uint64_t offset, uint8_t *bytes,
                         size_t length, ZenitVkDiagnostic *diag) {
    int status = buffer_range(b, offset, bytes, length, diag);
    if (status) return status;
    if (!b->coherent) {
        VkMappedMemoryRange range = { .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
            .memory = b->memory, .offset = 0, .size = VK_WHOLE_SIZE };
        status = resource_result(diag, "vkInvalidateMappedMemoryRanges", b->device->InvalidateMappedMemoryRanges(b->device->device, 1, &range));
        if (status) return status;
    }
    memcpy(bytes, (uint8_t *)b->mapped + offset, length);
    return ZENIT_VK_OK;
}

static int transfer_begin(ZenitVkDevice *d, VkCommandBuffer *command, ZenitVkDiagnostic *diag) {
    *command = VK_NULL_HANDLE;
    VkCommandBufferAllocateInfo alloc = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = d->pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkResult result = d->AllocateCommandBuffers(d->device, &alloc, command);
    if (result != VK_SUCCESS) return resource_result(diag, "vkAllocateCommandBuffers(transfer)", result);
    VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    result = d->BeginCommandBuffer(*command, &begin);
    if (result != VK_SUCCESS) {
        d->FreeCommandBuffers(d->device, d->pool, 1, command); *command = VK_NULL_HANDLE;
    }
    return resource_result(diag, "vkBeginCommandBuffer(transfer)", result);
}
static int transfer_finish(ZenitVkDevice *d, VkCommandBuffer command, ZenitVkDiagnostic *diag) {
    VkFence fence = VK_NULL_HANDLE;
    VkResult result = d->EndCommandBuffer(command);
    const char *operation = "vkEndCommandBuffer(transfer)";
    if (result != VK_SUCCESS) goto cleanup;
    VkFenceCreateInfo info = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    operation = "vkCreateFence(transfer)";
    result = d->CreateFence(d->device, &info, NULL, &fence);
    if (result != VK_SUCCESS) goto cleanup;
    VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1, .pCommandBuffers = &command };
    operation = "vkQueueSubmit(transfer)";
    result = d->QueueSubmit(d->queue, 1, &submit, fence);
    if (result != VK_SUCCESS) goto cleanup;
    operation = "vkWaitForFences(transfer)";
    result = d->WaitForFences(d->device, 1, &fence, VK_TRUE, UINT64_C(10000000000));
    if (result != VK_SUCCESS) d->DeviceWaitIdle(d->device);
cleanup:
    if (fence) d->DestroyFence(d->device, fence, NULL);
    d->FreeCommandBuffers(d->device, d->pool, 1, &command);
    return resource_result(diag, operation, result);
}
int zenit_vk_buffer_copy(ZenitVkBuffer *src, uint64_t src_offset, ZenitVkBuffer *dst,
                         uint64_t dst_offset, uint64_t size, ZenitVkDiagnostic *diag) {
    if (!src || !dst || src->device != dst->device || !size || src_offset > src->size ||
        size > src->size - src_offset || dst_offset > dst->size || size > dst->size - dst_offset ||
        (src == dst && src_offset < dst_offset + size && dst_offset < src_offset + size))
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "buffer copy range or device", VK_SUCCESS);
    ZenitVkDevice *d = src->device;
    VkCommandBuffer command;
    int status = transfer_begin(d, &command, diag);
    if (status) return status;
    VkMemoryBarrier before = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_HOST_WRITE_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT };
    d->CmdPipelineBarrier(command, VK_PIPELINE_STAGE_HOST_BIT | VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &before, 0, NULL, 0, NULL);
    VkBufferCopy region = { src_offset, dst_offset, size };
    d->CmdCopyBuffer(command, src->buffer, dst->buffer, 1, &region);
    VkMemoryBarrier after = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_HOST_READ_BIT | VK_ACCESS_MEMORY_READ_BIT };
    d->CmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_PIPELINE_STAGE_HOST_BIT | VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &after, 0, NULL, 0, NULL);
    return transfer_finish(d, command, diag);
}

void zenit_vk_texture_destroy(ZenitVkTexture *t) {
    if (!t) return;
    ZenitVkDevice *d = t->device;
    if (t->view) d->DestroyImageView(d->device, t->view, NULL);
    if (t->image) d->DestroyImage(d->device, t->image, NULL);
    if (t->memory) d->FreeMemory(d->device, t->memory, NULL);
    --d->live_resources;
    free(t);
}
int zenit_vk_texture_create(ZenitVkDevice *d, uint32_t width, uint32_t height,
                            uint32_t format, ZenitVkTexture **out, ZenitVkDiagnostic *diag) {
    if (!d || !out || !width || !height || width > d->properties.limits.maxImageDimension2D ||
        height > d->properties.limits.maxImageDimension2D || format < 1 || format > 4)
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "texture descriptor", VK_SUCCESS);
    *out = NULL;
    ZenitVkTexture *t = calloc(1, sizeof(*t));
    if (!t) return diagnostic(diag, ZENIT_VK_OUT_OF_MEMORY, "allocate texture owner", VK_ERROR_OUT_OF_HOST_MEMORY);
    t->device = d; t->width = width; t->height = height; t->texel_size = format == 1 ? 1 : format == 4 ? 8 : 4;
    t->format = format == 1 ? VK_FORMAT_R8_UNORM : format == 2 ? VK_FORMAT_R8G8B8A8_UNORM : format == 4 ? VK_FORMAT_R16G16B16A16_SFLOAT : VK_FORMAT_B8G8R8A8_UNORM;
    ++d->live_resources;
    VkImageCreateInfo info = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D, .format = t->format, .extent = { width, height, 1 },
        .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
            VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
    VkResult result = d->CreateImage(d->device, &info, NULL, &t->image);
    const char *operation = "vkCreateImage(texture)";
    if (result != VK_SUCCESS) goto fail;
    VkMemoryRequirements req;
    d->GetImageMemoryRequirements(d->device, t->image, &req);
    uint32_t type = memory_type(d, req.memoryTypeBits, 0, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (type == UINT32_MAX) { zenit_vk_texture_destroy(t); return diagnostic(diag, ZENIT_VK_NO_DEVICE, "texture memory type", VK_SUCCESS); }
    VkMemoryAllocateInfo alloc = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size, .memoryTypeIndex = type };
    operation = "vkAllocateMemory(texture)";
    result = d->AllocateMemory(d->device, &alloc, NULL, &t->memory);
    if (result != VK_SUCCESS) goto fail;
    operation = "vkBindImageMemory(texture)";
    result = d->BindImageMemory(d->device, t->image, t->memory, 0);
    if (result != VK_SUCCESS) goto fail;
    VkImageViewCreateInfo view = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = t->image, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = t->format,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    operation = "vkCreateImageView(texture)";
    result = d->CreateImageView(d->device, &view, NULL, &t->view);
    if (result != VK_SUCCESS) goto fail;
    *out = t;
    return ZENIT_VK_OK;
fail:
    zenit_vk_texture_destroy(t);
    return resource_result(diag, operation, result);
}
static void texture_barrier(ZenitVkTexture *t, VkCommandBuffer command, VkImageLayout next) {
    VkImageMemoryBarrier barrier = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = t->layout == VK_IMAGE_LAYOUT_UNDEFINED ? 0 : VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
        .dstAccessMask = next == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL ? VK_ACCESS_TRANSFER_WRITE_BIT : VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = t->layout, .newLayout = next,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = t->image, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    t->device->CmdPipelineBarrier(command, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
}
int zenit_vk_texture_transfer(ZenitVkTexture *t, uint32_t x, uint32_t y,
                              uint32_t width, uint32_t height, uint8_t *bytes,
                              size_t length, uint32_t stride, int upload, ZenitVkDiagnostic *diag) {
    if (!t || !bytes || !width || !height || x > t->width || width > t->width - x ||
        y > t->height || height > t->height - y || (uint64_t)width * t->texel_size > stride ||
        (uint64_t)stride * height > length || (!upload && t->layout == VK_IMAGE_LAYOUT_UNDEFINED))
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "texture transfer region/stride/state", VK_SUCCESS);
    ZenitVkDevice *d = t->device;
    ZenitVkBuffer *staging = NULL;
    const size_t row = (size_t)width * t->texel_size;
    if (row > SIZE_MAX / height) return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "texture transfer size", VK_SUCCESS);
    int status = zenit_vk_buffer_create(d, row * height, 12, &staging, diag);
    if (status) return status;
    if (upload) {
        for (uint32_t i = 0; i < height; ++i) {
            status = zenit_vk_buffer_write(staging, i * row, bytes + (size_t)i * stride, row, diag);
            if (status) goto cleanup;
        }
    }
    VkCommandBuffer command;
    status = transfer_begin(d, &command, diag);
    if (status) goto cleanup;
    VkImageLayout next = upload ? VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL : VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    texture_barrier(t, command, next);
    VkBufferImageCopy region = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .imageOffset = { (int32_t)x, (int32_t)y, 0 }, .imageExtent = { width, height, 1 } };
    if (upload) d->CmdCopyBufferToImage(command, staging->buffer, t->image, next, 1, &region);
    else {
        d->CmdCopyImageToBuffer(command, t->image, next, staging->buffer, 1, &region);
        VkMemoryBarrier barrier = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
        d->CmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
            0, 1, &barrier, 0, NULL, 0, NULL);
    }
    status = transfer_finish(d, command, diag);
    if (status) goto cleanup;
    t->layout = next;
    if (!upload) for (uint32_t i = 0; i < height; ++i) {
        status = zenit_vk_buffer_read(staging, i * row, bytes + (size_t)i * stride, row, diag);
        if (status) goto cleanup;
    }
cleanup:
    zenit_vk_buffer_destroy(staging);
    return status;
}

static void transfer_image_barrier(ZenitVkTexture *texture, VkCommandBuffer command,
    VkImageLayout next, VkAccessFlags access) {
    VkImageMemoryBarrier barrier = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = texture->layout == VK_IMAGE_LAYOUT_UNDEFINED ? 0 : VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
        .dstAccessMask = access, .oldLayout = texture->layout, .newLayout = next,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = texture->image, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    texture->device->CmdPipelineBarrier(command, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
}
int zenit_vk_texture_clear(ZenitVkTexture *texture, const float rgba[4], ZenitVkDiagnostic *diag) {
    if (!texture || !rgba) return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "texture clear", VK_SUCCESS);
    for (uint32_t i = 0; i < 4; ++i) if (!isfinite(rgba[i]))
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "texture clear color", VK_SUCCESS);
    VkCommandBuffer command = VK_NULL_HANDLE;
    int status = transfer_begin(texture->device, &command, diag);
    if (status) return status;
    transfer_image_barrier(texture, command, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_ACCESS_TRANSFER_WRITE_BIT);
    VkClearColorValue color;
    memcpy(color.float32, rgba, sizeof(color.float32));
    VkImageSubresourceRange range = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
    texture->device->CmdClearColorImage(command, texture->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &range);
    status = transfer_finish(texture->device, command, diag);
    if (!status) texture->layout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    return status;
}
int zenit_vk_texture_copy(ZenitVkTexture *src, uint32_t sx, uint32_t sy,
    ZenitVkTexture *dst, uint32_t dx, uint32_t dy, uint32_t width, uint32_t height, ZenitVkDiagnostic *diag) {
    if (!src || !dst || src->device != dst->device || src->format != dst->format || !width || !height ||
        src->layout == VK_IMAGE_LAYOUT_UNDEFINED || sx > src->width || width > src->width - sx ||
        sy > src->height || height > src->height - sy || dx > dst->width || width > dst->width - dx ||
        dy > dst->height || height > dst->height - dy ||
        (src == dst && sx < dx + width && dx < sx + width && sy < dy + height && dy < sy + height))
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "texture copy region", VK_SUCCESS);
    VkCommandBuffer command = VK_NULL_HANDLE;
    int status = transfer_begin(src->device, &command, diag);
    if (status) return status;
    const VkImageLayout sl = src == dst ? VK_IMAGE_LAYOUT_GENERAL : VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    const VkImageLayout dl = src == dst ? VK_IMAGE_LAYOUT_GENERAL : VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    if (src == dst) transfer_image_barrier(src, command, sl, VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT);
    else {
        transfer_image_barrier(src, command, sl, VK_ACCESS_TRANSFER_READ_BIT);
        transfer_image_barrier(dst, command, dl, VK_ACCESS_TRANSFER_WRITE_BIT);
    }
    VkImageCopy copy = { .srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .srcOffset = { (int32_t)sx, (int32_t)sy, 0 }, .dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .dstOffset = { (int32_t)dx, (int32_t)dy, 0 }, .extent = { width, height, 1 } };
    src->device->CmdCopyImage(command, src->image, sl, dst->image, dl, 1, &copy);
    status = transfer_finish(src->device, command, diag);
    if (!status) { src->layout = sl; dst->layout = dl; }
    return status;
}
