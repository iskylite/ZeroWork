/* Linux Vulkan bootstrap. Vulkan handles stay inside the native bridge. */
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>
#include <vulkan/vulkan_wayland.h>
#include "vulkan_device.h"
#include <dlfcn.h>
#include <math.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "png.inc"

#define INSTANCE_FUNCTIONS(X) \
    X(DestroyInstance) X(EnumeratePhysicalDevices) X(GetPhysicalDeviceProperties) \
    X(GetPhysicalDeviceQueueFamilyProperties) X(GetPhysicalDeviceMemoryProperties) \
    X(GetPhysicalDeviceFormatProperties) X(GetPhysicalDeviceFeatures) X(CreateDevice) X(GetDeviceProcAddr)
#define DEVICE_FUNCTIONS(X) \
    X(DestroyDevice) X(GetDeviceQueue) X(DeviceWaitIdle) X(CreateCommandPool) \
    X(DestroyCommandPool) X(AllocateCommandBuffers) X(FreeCommandBuffers) \
    X(BeginCommandBuffer) X(EndCommandBuffer) X(CreateImage) X(DestroyImage) \
    X(GetImageMemoryRequirements) X(AllocateMemory) X(FreeMemory) X(BindImageMemory) \
    X(CreateBuffer) X(DestroyBuffer) X(GetBufferMemoryRequirements) X(BindBufferMemory) \
    X(MapMemory) X(UnmapMemory) X(InvalidateMappedMemoryRanges) X(CreateImageView) \
    X(DestroyImageView) X(CreateRenderPass) X(DestroyRenderPass) X(CreateFramebuffer) \
    X(DestroyFramebuffer) X(CreateShaderModule) X(DestroyShaderModule) \
    X(CreatePipelineLayout) X(DestroyPipelineLayout) X(CreateGraphicsPipelines) \
    X(DestroyPipeline) X(CmdBeginRenderPass) X(CmdEndRenderPass) X(CmdBindPipeline) \
    X(CmdDraw) X(CmdPipelineBarrier) X(CmdCopyImageToBuffer) X(CreateFence) \
    X(DestroyFence) X(QueueSubmit) X(WaitForFences) X(FlushMappedMemoryRanges) \
    X(CmdClearColorImage) X(CmdCopyBuffer) X(CmdCopyImage) X(CmdCopyBufferToImage) X(CreateDescriptorSetLayout) \
    X(DestroyDescriptorSetLayout) X(CmdSetViewport) X(CmdSetScissor) \
    X(CreateDescriptorPool) X(DestroyDescriptorPool) X(AllocateDescriptorSets) \
    X(UpdateDescriptorSets) X(CmdBindDescriptorSets) X(CreateSampler) X(DestroySampler)

#define WSI_INSTANCE_FUNCTIONS(X) \
    X(CreateWaylandSurfaceKHR) X(DestroySurfaceKHR) X(GetPhysicalDeviceSurfaceSupportKHR) \
    X(GetPhysicalDeviceSurfaceCapabilitiesKHR) X(GetPhysicalDeviceSurfaceFormatsKHR) \
    X(GetPhysicalDeviceFeatures2)
#define WSI_DEVICE_FUNCTIONS(X) \
    X(CreateSwapchainKHR) X(DestroySwapchainKHR) X(GetSwapchainImagesKHR) \
    X(AcquireNextImageKHR) X(QueuePresentKHR) X(CreateSemaphore) X(DestroySemaphore) \
    X(ResetFences)

/* Wayland window hook (weak: probes link the device without a window). */
__attribute__((weak)) void zenit_wayland_before_present(void *wl_surface, uint32_t pixel_width, uint32_t pixel_height);
struct ZenitVkDevice {
    void *wayland_surface;
    void *loader;
    PFN_vkGetInstanceProcAddr get_instance_proc;
    VkInstance instance;
    VkPhysicalDevice physical;
    VkDevice device;
    VkQueue queue;
    VkCommandPool pool;
    VkPhysicalDeviceProperties properties;
    VkPhysicalDeviceMemoryProperties memory;
    uint32_t queue_family;
    uint32_t live_resources;
    VkDebugUtilsMessengerEXT messenger;
    PFN_vkDestroyDebugUtilsMessengerEXT destroy_messenger;
    _Atomic uint32_t validation_errors;
    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkExtent2D extent;
    VkImage *swapchain_images;
    VkSemaphore acquire_semaphore;
    VkSemaphore *present_semaphores;
    VkFence *present_fences;
    uint8_t *present_pending;
    uint32_t image_count;
    int swapchain_outdated;
#define DECLARE(name) PFN_vk##name name;
    INSTANCE_FUNCTIONS(DECLARE)
    DEVICE_FUNCTIONS(DECLARE)
    WSI_INSTANCE_FUNCTIONS(DECLARE)
    WSI_DEVICE_FUNCTIONS(DECLARE)
#undef DECLARE
};

static int destroy_swapchain(ZenitVkDevice *d, ZenitVkDiagnostic *diag);

static int diagnostic(ZenitVkDiagnostic *d, int status, const char *operation, VkResult result) {
    if (d) {
        snprintf(d->operation, sizeof(d->operation), "%s", operation);
        d->vk_result = result;
    }
    return status;
}

static VKAPI_ATTR VkBool32 VKAPI_CALL validation_callback(
    VkDebugUtilsMessageSeverityFlagBitsEXT severity, VkDebugUtilsMessageTypeFlagsEXT type,
    const VkDebugUtilsMessengerCallbackDataEXT *data, void *context) {
    (void)type;
    ZenitVkDevice *d = context;
    if (severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT)
        atomic_fetch_add_explicit(&d->validation_errors, 1, memory_order_relaxed);
    fprintf(stderr, "VULKAN_VALIDATION: %s\n", data->pMessage);
    return VK_FALSE;
}

uint32_t zenit_vk_validation_errors(const ZenitVkDevice *d) {
    return d ? atomic_load_explicit(&d->validation_errors, memory_order_relaxed) : 0;
}

int32_t zenit_vk_device_destroy(ZenitVkDevice *d) {
    if (!d) return 0;
    if (d->live_resources) return -2;
    if (d->device) {
        if (d->DeviceWaitIdle) d->DeviceWaitIdle(d->device);
        if (destroy_swapchain(d, NULL) != ZENIT_VK_OK) return -1;
        if (d->pool && d->DestroyCommandPool) d->DestroyCommandPool(d->device, d->pool, NULL);
        if (d->DestroyDevice) d->DestroyDevice(d->device, NULL);
    }
    if (d->surface && d->DestroySurfaceKHR) d->DestroySurfaceKHR(d->instance, d->surface, NULL);
    if (d->messenger && d->destroy_messenger)
        d->destroy_messenger(d->instance, d->messenger, NULL);
    if (d->instance && d->DestroyInstance) d->DestroyInstance(d->instance, NULL);
    if (d->loader) dlclose(d->loader);
    uint32_t errors = zenit_vk_validation_errors(d);
    free(d);
    return errors > INT32_MAX ? INT32_MAX : (int32_t)errors;
}

static int device_score(VkPhysicalDeviceType type) {
    switch (type) {
    case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: return 100;
    case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return 90;
    case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU: return 80;
    case VK_PHYSICAL_DEVICE_TYPE_CPU: return 10;
    default: return 0; /* Unknown types are not evidence of acceleration. */
    }
}

int zenit_vk_device_create(int allow_software, int require_validation,
                           void *wayland_display, void *wayland_surface,
                           ZenitVkDevice **out, ZenitVkDeviceInfo *info,
                           ZenitVkDiagnostic *diag) {
    if (!out || !info || (!!wayland_display != !!wayland_surface)) return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "create arguments", VK_SUCCESS);
    *out = NULL;
    memset(info, 0, sizeof(*info));
    ZenitVkDevice *d = calloc(1, sizeof(*d));
    if (!d) return diagnostic(diag, ZENIT_VK_OUT_OF_MEMORY, "allocate device", VK_ERROR_OUT_OF_HOST_MEMORY);
    atomic_init(&d->validation_errors, 0);
    int status = ZENIT_VK_API_FAILED;
    VkResult result;
    VkPhysicalDevice *physical = NULL;
    d->loader = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!d->loader) {
        status = diagnostic(diag, ZENIT_VK_LOADER_UNAVAILABLE, "dlopen libvulkan.so.1", VK_SUCCESS);
        goto fail;
    }
    d->get_instance_proc = (PFN_vkGetInstanceProcAddr)dlsym(d->loader, "vkGetInstanceProcAddr");
    if (!d->get_instance_proc) {
        status = diagnostic(diag, ZENIT_VK_SYMBOL_UNAVAILABLE, "vkGetInstanceProcAddr", VK_SUCCESS);
        goto fail;
    }
    PFN_vkCreateInstance create_instance = (PFN_vkCreateInstance)d->get_instance_proc(NULL, "vkCreateInstance");
    if (!create_instance) {
        status = diagnostic(diag, ZENIT_VK_SYMBOL_UNAVAILABLE, "vkCreateInstance", VK_SUCCESS);
        goto fail;
    }
    const char *layer = "VK_LAYER_KHRONOS_validation";
    const int wsi = wayland_surface != NULL;
    const char *extensions[5];
    uint32_t extension_count = 0;
    if (require_validation) extensions[extension_count++] = VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
    if (wsi) {
        extensions[extension_count++] = VK_KHR_SURFACE_EXTENSION_NAME;
        extensions[extension_count++] = VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME;
        extensions[extension_count++] = VK_KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME;
        extensions[extension_count++] = VK_EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME;
    }
    VkApplicationInfo application = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "Zenit Vulkan",
        .pEngineName = "Zenit", .apiVersion = VK_API_VERSION_1_1,
    };
    VkDebugUtilsMessengerCreateInfoEXT debug_info = {
        .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                           VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                       VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                       VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = validation_callback, .pUserData = d,
    };
    VkInstanceCreateInfo instance_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &application,
        .enabledLayerCount = require_validation ? 1 : 0, .ppEnabledLayerNames = &layer,
        .enabledExtensionCount = extension_count, .ppEnabledExtensionNames = extensions,
        .pNext = require_validation ? &debug_info : NULL,
    };
    result = create_instance(&instance_info, NULL, &d->instance);
    if (result != VK_SUCCESS) {
        status = diagnostic(diag, require_validation &&
            (result == VK_ERROR_LAYER_NOT_PRESENT || (!wsi && result == VK_ERROR_EXTENSION_NOT_PRESENT))
            ? ZENIT_VK_VALIDATION_UNAVAILABLE : ZENIT_VK_API_FAILED, "vkCreateInstance", result);
        goto fail;
    }
#define LOAD_INSTANCE(name) \
    d->name = (PFN_vk##name)d->get_instance_proc(d->instance, "vk" #name); \
    if (!d->name) { status = diagnostic(diag, ZENIT_VK_SYMBOL_UNAVAILABLE, "vk" #name, VK_SUCCESS); goto fail; }
    INSTANCE_FUNCTIONS(LOAD_INSTANCE)
    if (wsi) { WSI_INSTANCE_FUNCTIONS(LOAD_INSTANCE) }
#undef LOAD_INSTANCE
    if (require_validation) {
        PFN_vkCreateDebugUtilsMessengerEXT create =
            (PFN_vkCreateDebugUtilsMessengerEXT)d->get_instance_proc(d->instance, "vkCreateDebugUtilsMessengerEXT");
        d->destroy_messenger = (PFN_vkDestroyDebugUtilsMessengerEXT)
            d->get_instance_proc(d->instance, "vkDestroyDebugUtilsMessengerEXT");
        if (!create || !d->destroy_messenger) {
            status = diagnostic(diag, ZENIT_VK_SYMBOL_UNAVAILABLE, "debug messenger", VK_SUCCESS);
            goto fail;
        }
        result = create(d->instance, &debug_info, NULL, &d->messenger);
        if (result != VK_SUCCESS) { status = diagnostic(diag, ZENIT_VK_API_FAILED, "vkCreateDebugUtilsMessengerEXT", result); goto fail; }
    }
    if (wsi) {
        d->wayland_surface = wayland_surface;
        VkWaylandSurfaceCreateInfoKHR surface_info = { .sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
            .display = wayland_display, .surface = wayland_surface };
        result = d->CreateWaylandSurfaceKHR(d->instance, &surface_info, NULL, &d->surface);
        if (result != VK_SUCCESS) { status = diagnostic(diag, ZENIT_VK_API_FAILED, "vkCreateWaylandSurfaceKHR", result); goto fail; }
    }
    uint32_t count = 0;
    result = d->EnumeratePhysicalDevices(d->instance, &count, NULL);
    if (result != VK_SUCCESS) { status = diagnostic(diag, ZENIT_VK_API_FAILED, "vkEnumeratePhysicalDevices count", result); goto fail; }
    if (!count) { status = diagnostic(diag, ZENIT_VK_NO_DEVICE, "no physical device", VK_SUCCESS); goto fail; }
    /* Retry changing enumerations instead of accepting an incomplete list. */
    for (unsigned attempt = 0; attempt < 4; ++attempt) {
        free(physical);
        physical = calloc(count, sizeof(*physical));
        if (!physical) { status = diagnostic(diag, ZENIT_VK_OUT_OF_MEMORY, "physical devices", VK_ERROR_OUT_OF_HOST_MEMORY); goto fail; }
        result = d->EnumeratePhysicalDevices(d->instance, &count, physical);
        if (result == VK_SUCCESS) break;
        if (result != VK_INCOMPLETE) break;
        result = d->EnumeratePhysicalDevices(d->instance, &count, NULL);
        if (result != VK_SUCCESS) break;
        result = VK_INCOMPLETE;
    }
    if (result != VK_SUCCESS) { status = diagnostic(diag, ZENIT_VK_API_FAILED, "vkEnumeratePhysicalDevices", result); goto fail; }
    int best = -1;
    int software_seen = 0;
    for (uint32_t i = 0; i < count; ++i) {
        VkPhysicalDeviceProperties p;
        d->GetPhysicalDeviceProperties(physical[i], &p);
        if (p.apiVersion < VK_API_VERSION_1_1) continue;
        const int score = device_score(p.deviceType);
        if (score <= 10 && !allow_software) { software_seen = 1; continue; }
        if (wsi) {
            VkPhysicalDeviceSwapchainMaintenance1FeaturesEXT maintenance = {
                .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT };
            VkPhysicalDeviceFeatures2 features = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
                .pNext = &maintenance };
            d->GetPhysicalDeviceFeatures2(physical[i], &features);
            if (!maintenance.swapchainMaintenance1) continue;
        }
        VkFormatProperties format;
        d->GetPhysicalDeviceFormatProperties(physical[i], VK_FORMAT_B8G8R8A8_UNORM, &format);
        if (!(format.optimalTilingFeatures & VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT)) continue;
        uint32_t queue_count = 0;
        d->GetPhysicalDeviceQueueFamilyProperties(physical[i], &queue_count, NULL);
        if (!queue_count) continue;
        VkQueueFamilyProperties *queues = calloc(queue_count, sizeof(*queues));
        if (!queues) { status = diagnostic(diag, ZENIT_VK_OUT_OF_MEMORY, "queue families", VK_ERROR_OUT_OF_HOST_MEMORY); goto fail; }
        d->GetPhysicalDeviceQueueFamilyProperties(physical[i], &queue_count, queues);
        for (uint32_t q = 0; q < queue_count; ++q) {
            VkBool32 present = VK_TRUE;
            if (wsi) {
                result = d->GetPhysicalDeviceSurfaceSupportKHR(physical[i], q, d->surface, &present);
                if (result != VK_SUCCESS) { free(queues); status = diagnostic(diag, ZENIT_VK_API_FAILED, "vkGetPhysicalDeviceSurfaceSupportKHR", result); goto fail; }
            }
            if (present && queues[q].queueCount && (queues[q].queueFlags & VK_QUEUE_GRAPHICS_BIT) && score > best) {
                best = score;
                d->physical = physical[i]; d->queue_family = q; d->properties = p;
                break;
            }
        }
        free(queues);
    }
    if (!d->physical) {
        status = diagnostic(diag, software_seen ? ZENIT_VK_SOFTWARE_ONLY : ZENIT_VK_NO_DEVICE,
                            "no eligible graphics device", VK_SUCCESS);
        goto fail;
    }
    const float priority = 1.0f;
    VkDeviceQueueCreateInfo queue_info = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = d->queue_family, .queueCount = 1, .pQueuePriorities = &priority };
    VkPhysicalDeviceFeatures available_features;
    d->GetPhysicalDeviceFeatures(d->physical, &available_features);
    VkPhysicalDeviceFeatures enabled_features = {
        .robustBufferAccess = available_features.robustBufferAccess };
    VkDeviceCreateInfo device_info = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue_info, .pEnabledFeatures = &enabled_features };
    const char *device_extensions[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME, VK_EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME };
    VkPhysicalDeviceSwapchainMaintenance1FeaturesEXT maintenance_enable = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT,
        .swapchainMaintenance1 = VK_TRUE };
    if (wsi) {
        device_info.enabledExtensionCount = 2; device_info.ppEnabledExtensionNames = device_extensions;
        device_info.pNext = &maintenance_enable;
    }
    result = d->CreateDevice(d->physical, &device_info, NULL, &d->device);
    if (result != VK_SUCCESS) { status = diagnostic(diag, ZENIT_VK_API_FAILED, "vkCreateDevice", result); goto fail; }
#define LOAD_DEVICE(name) \
    d->name = (PFN_vk##name)d->GetDeviceProcAddr(d->device, "vk" #name); \
    if (!d->name) { status = diagnostic(diag, ZENIT_VK_SYMBOL_UNAVAILABLE, "vk" #name, VK_SUCCESS); goto fail; }
    DEVICE_FUNCTIONS(LOAD_DEVICE)
    if (wsi) { WSI_DEVICE_FUNCTIONS(LOAD_DEVICE) }
#undef LOAD_DEVICE
    d->GetDeviceQueue(d->device, d->queue_family, 0, &d->queue);
    d->GetPhysicalDeviceMemoryProperties(d->physical, &d->memory);
    VkCommandPoolCreateInfo pool_info = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT, .queueFamilyIndex = d->queue_family };
    result = d->CreateCommandPool(d->device, &pool_info, NULL, &d->pool);
    if (result != VK_SUCCESS) { status = diagnostic(diag, ZENIT_VK_API_FAILED, "vkCreateCommandPool", result); goto fail; }
    snprintf(info->name, sizeof(info->name), "%s", d->properties.deviceName);
    info->api_version = d->properties.apiVersion; info->driver_version = d->properties.driverVersion;
    info->vendor_id = d->properties.vendorID; info->device_id = d->properties.deviceID;
    info->device_type = d->properties.deviceType; info->queue_family = d->queue_family;
    info->max_image_dimension_2d = d->properties.limits.maxImageDimension2D;
    free(physical);
    *out = d;
    return diagnostic(diag, ZENIT_VK_OK, "ready", VK_SUCCESS);
fail:
    free(physical);
    zenit_vk_device_destroy(d);
    return status;
}

static uint32_t memory_type(ZenitVkDevice *d, uint32_t bits,
                            VkMemoryPropertyFlags required, VkMemoryPropertyFlags preferred) {
    uint32_t fallback = UINT32_MAX;
    for (uint32_t i = 0; i < d->memory.memoryTypeCount; ++i) {
        VkMemoryPropertyFlags flags = d->memory.memoryTypes[i].propertyFlags;
        if (!(bits & (1u << i)) || (flags & required) != required) continue;
        if ((flags & preferred) == preferred) return i;
        fallback = i;
    }
    return fallback;
}

#include "vulkan_resources.inc"
#include "vulkan_pipeline.inc"

int zenit_vk_render_probe(ZenitVkDevice *d, uint32_t width, uint32_t height,
                          uint8_t *bgra, size_t length,
                          const uint32_t *vertex_spirv, size_t vertex_size,
                          const uint32_t *fragment_spirv, size_t fragment_size,
                          ZenitVkDiagnostic *diag) {
    if (!d || !width || !height || !bgra || !vertex_spirv || !fragment_spirv)
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "null render argument or zero extent", VK_SUCCESS);
    if (vertex_size < 20 || fragment_size < 20 || vertex_size % 4 || fragment_size % 4)
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "SPIR-V byte length", VK_SUCCESS);
    if (((uintptr_t)vertex_spirv % 4) || ((uintptr_t)fragment_spirv % 4))
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "SPIR-V address alignment", VK_SUCCESS);
    if (vertex_spirv[0] != 0x07230203 || fragment_spirv[0] != 0x07230203)
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "SPIR-V magic", VK_SUCCESS);
    if (width > d->properties.limits.maxImageDimension2D || height > d->properties.limits.maxImageDimension2D)
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "image extent exceeds device limits", VK_SUCCESS);
    if ((uint64_t)width * height > SIZE_MAX / 4 || length != (size_t)width * height * 4)
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "BGRA readback byte length", VK_SUCCESS);
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory image_memory = VK_NULL_HANDLE, buffer_memory = VK_NULL_HANDLE;
    VkBuffer buffer = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    VkRenderPass pass = VK_NULL_HANDLE;
    VkFramebuffer framebuffer = VK_NULL_HANDLE;
    VkShaderModule vertex = VK_NULL_HANDLE, fragment = VK_NULL_HANDLE;
    VkPipelineLayout layout = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    void *mapped = NULL;
    int submitted = 0;
    int status = ZENIT_VK_API_FAILED;
    VkResult result;
#define CHECK(operation) do { result = (operation); if (result != VK_SUCCESS) { \
    status = diagnostic(diag, ZENIT_VK_API_FAILED, #operation, result); goto cleanup; } } while (0)
    VkImageCreateInfo image_info = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_B8G8R8A8_UNORM,
        .extent = { width, height, 1 }, .mipLevels = 1, .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
    CHECK(d->CreateImage(d->device, &image_info, NULL, &image));
    VkMemoryRequirements requirements;
    d->GetImageMemoryRequirements(d->device, image, &requirements);
    uint32_t type = memory_type(d, requirements.memoryTypeBits, 0, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (type == UINT32_MAX) { status = diagnostic(diag, ZENIT_VK_NO_DEVICE, "image memory type", VK_SUCCESS); goto cleanup; }
    VkMemoryAllocateInfo allocation = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size, .memoryTypeIndex = type };
    CHECK(d->AllocateMemory(d->device, &allocation, NULL, &image_memory));
    CHECK(d->BindImageMemory(d->device, image, image_memory, 0));
    VkBufferCreateInfo buffer_info = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = length, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    CHECK(d->CreateBuffer(d->device, &buffer_info, NULL, &buffer));
    d->GetBufferMemoryRequirements(d->device, buffer, &requirements);
    type = memory_type(d, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
        VK_MEMORY_PROPERTY_HOST_COHERENT_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT);
    if (type == UINT32_MAX) { status = diagnostic(diag, ZENIT_VK_NO_DEVICE, "readback memory type", VK_SUCCESS); goto cleanup; }
    int coherent = (d->memory.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
    allocation.allocationSize = requirements.size; allocation.memoryTypeIndex = type;
    CHECK(d->AllocateMemory(d->device, &allocation, NULL, &buffer_memory));
    CHECK(d->BindBufferMemory(d->device, buffer, buffer_memory, 0));
    VkImageViewCreateInfo view_info = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_B8G8R8A8_UNORM,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    CHECK(d->CreateImageView(d->device, &view_info, NULL, &view));
    VkAttachmentDescription attachment = { .format = VK_FORMAT_B8G8R8A8_UNORM,
        .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE, .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL };
    VkAttachmentReference reference = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription subpass = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1, .pColorAttachments = &reference };
    VkSubpassDependency dependencies[2] = {
        { .srcSubpass = VK_SUBPASS_EXTERNAL, .dstSubpass = 0,
          .srcStageMask = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
          .dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
          .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT },
        { .srcSubpass = 0, .dstSubpass = VK_SUBPASS_EXTERNAL,
          .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
          .dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT,
          .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT },
    };
    VkRenderPassCreateInfo pass_info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1, .pAttachments = &attachment, .subpassCount = 1, .pSubpasses = &subpass,
        .dependencyCount = 2, .pDependencies = dependencies };
    CHECK(d->CreateRenderPass(d->device, &pass_info, NULL, &pass));
    VkFramebufferCreateInfo framebuffer_info = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = pass, .attachmentCount = 1, .pAttachments = &view,
        .width = width, .height = height, .layers = 1 };
    CHECK(d->CreateFramebuffer(d->device, &framebuffer_info, NULL, &framebuffer));
    VkShaderModuleCreateInfo shader_info = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = vertex_size, .pCode = vertex_spirv };
    CHECK(d->CreateShaderModule(d->device, &shader_info, NULL, &vertex));
    shader_info.codeSize = fragment_size; shader_info.pCode = fragment_spirv;
    CHECK(d->CreateShaderModule(d->device, &shader_info, NULL, &fragment));
    VkPipelineLayoutCreateInfo layout_info = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    CHECK(d->CreatePipelineLayout(d->device, &layout_info, NULL, &layout));
    VkPipelineShaderStageCreateInfo stages[2] = {
        { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
          .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vertex, .pName = "main" },
        { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
          .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fragment, .pName = "main" },
    };
    VkPipelineVertexInputStateCreateInfo input = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    VkPipelineInputAssemblyStateCreateInfo assembly = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
    VkViewport viewport = { 0, 0, (float)width, (float)height, 0, 1 };
    VkRect2D scissor = { { 0, 0 }, { width, height } };
    VkPipelineViewportStateCreateInfo viewport_info = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1, .pViewports = &viewport, .scissorCount = 1, .pScissors = &scissor };
    VkPipelineRasterizationStateCreateInfo raster = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE,
        .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1.0f };
    VkPipelineMultisampleStateCreateInfo multisample = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
    VkPipelineColorBlendAttachmentState blend_attachment = { .colorWriteMask = 0xf };
    VkPipelineColorBlendStateCreateInfo blend = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1, .pAttachments = &blend_attachment };
    VkGraphicsPipelineCreateInfo pipeline_info = { .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2, .pStages = stages, .pVertexInputState = &input,
        .pInputAssemblyState = &assembly, .pViewportState = &viewport_info,
        .pRasterizationState = &raster, .pMultisampleState = &multisample,
        .pColorBlendState = &blend, .layout = layout, .renderPass = pass };
    CHECK(d->CreateGraphicsPipelines(d->device, VK_NULL_HANDLE, 1, &pipeline_info, NULL, &pipeline));
    VkCommandBufferAllocateInfo command_info = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = d->pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    CHECK(d->AllocateCommandBuffers(d->device, &command_info, &command));
    VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    CHECK(d->BeginCommandBuffer(command, &begin));
    VkClearValue clear = { .color = { .float32 = { 1, 0, 0, 1 } } };
    VkRenderPassBeginInfo render_begin = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = pass, .framebuffer = framebuffer, .renderArea = scissor,
        .clearValueCount = 1, .pClearValues = &clear };
    d->CmdBeginRenderPass(command, &render_begin, VK_SUBPASS_CONTENTS_INLINE);
    d->CmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    d->CmdDraw(command, 3, 1, 0, 0);
    d->CmdEndRenderPass(command);
    VkBufferImageCopy copy = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .imageExtent = { width, height, 1 } };
    d->CmdCopyImageToBuffer(command, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &copy);
    VkBufferMemoryBarrier host_barrier = { .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer = buffer, .size = VK_WHOLE_SIZE };
    d->CmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
        0, 0, NULL, 1, &host_barrier, 0, NULL);
    CHECK(d->EndCommandBuffer(command));
    VkFenceCreateInfo fence_info = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    CHECK(d->CreateFence(d->device, &fence_info, NULL, &fence));
    VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1, .pCommandBuffers = &command };
    CHECK(d->QueueSubmit(d->queue, 1, &submit, fence));
    submitted = 1;
    CHECK(d->WaitForFences(d->device, 1, &fence, VK_TRUE, 10000000000ull));
    submitted = 0;
    /* Map the complete allocation so WHOLE_SIZE is atom-aligned even when
     * the pixel payload isn't a multiple of nonCoherentAtomSize. */
    CHECK(d->MapMemory(d->device, buffer_memory, 0, VK_WHOLE_SIZE, 0, &mapped));
    if (!coherent) {
        VkMappedMemoryRange range = { .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
            .memory = buffer_memory, .size = VK_WHOLE_SIZE };
        CHECK(d->InvalidateMappedMemoryRanges(d->device, 1, &range));
    }
    memcpy(bgra, mapped, length);
    status = diagnostic(diag, ZENIT_VK_OK, "render/readback complete", VK_SUCCESS);
cleanup:
    /* A failed wait does not make submitted resources safe to destroy. */
    if (submitted) d->DeviceWaitIdle(d->device);
    if (mapped) d->UnmapMemory(d->device, buffer_memory);
    if (fence) d->DestroyFence(d->device, fence, NULL);
    if (command) d->FreeCommandBuffers(d->device, d->pool, 1, &command);
    if (pipeline) d->DestroyPipeline(d->device, pipeline, NULL);
    if (layout) d->DestroyPipelineLayout(d->device, layout, NULL);
    if (fragment) d->DestroyShaderModule(d->device, fragment, NULL);
    if (vertex) d->DestroyShaderModule(d->device, vertex, NULL);
    if (framebuffer) d->DestroyFramebuffer(d->device, framebuffer, NULL);
    if (pass) d->DestroyRenderPass(d->device, pass, NULL);
    if (view) d->DestroyImageView(d->device, view, NULL);
    if (image) d->DestroyImage(d->device, image, NULL);
    if (image_memory) d->FreeMemory(d->device, image_memory, NULL);
    if (buffer) d->DestroyBuffer(d->device, buffer, NULL);
    if (buffer_memory) d->FreeMemory(d->device, buffer_memory, NULL);
#undef CHECK
    return status;
}

static int surface_result(ZenitVkDiagnostic *diag, const char *operation, VkResult result) {
    int status = ZENIT_VK_API_FAILED;
    if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR) status = ZENIT_VK_SURFACE_OUTDATED;
    else if (result == VK_ERROR_SURFACE_LOST_KHR) status = ZENIT_VK_SURFACE_LOST;
    else if (result == VK_TIMEOUT || result == VK_NOT_READY) status = ZENIT_VK_TIMEOUT;
    return diagnostic(diag, status, operation, result);
}

static int destroy_swapchain(ZenitVkDevice *d, ZenitVkDiagnostic *diag) {
    /* Queue submission fences do not retire presentation operations. The WSI
     * bootstrap explicitly requires EXT_swapchain_maintenance1 and waits for
     * each present fence before semaphore reuse or swapchain destruction. */
    for (uint32_t i = 0; i < d->image_count; ++i) if (d->present_pending && d->present_pending[i]) {
        VkResult result = d->WaitForFences(d->device, 1, &d->present_fences[i], VK_TRUE, 10000000000ull);
        if (result != VK_SUCCESS && result != VK_ERROR_DEVICE_LOST)
            return surface_result(diag, "wait retired presentation", result);
    }
    for (uint32_t i = 0; i < d->image_count; ++i) {
        if (d->present_semaphores && d->present_semaphores[i]) d->DestroySemaphore(d->device, d->present_semaphores[i], NULL);
        if (d->present_fences && d->present_fences[i]) d->DestroyFence(d->device, d->present_fences[i], NULL);
    }
    if (d->acquire_semaphore) d->DestroySemaphore(d->device, d->acquire_semaphore, NULL);
    if (d->swapchain) d->DestroySwapchainKHR(d->device, d->swapchain, NULL);
    free(d->present_semaphores); free(d->present_fences); free(d->present_pending); free(d->swapchain_images);
    d->present_semaphores = NULL; d->present_fences = NULL; d->present_pending = NULL; d->swapchain_images = NULL;
    d->acquire_semaphore = VK_NULL_HANDLE; d->swapchain = VK_NULL_HANDLE; d->image_count = 0;
    return ZENIT_VK_OK;
}

static uint32_t clamp_extent(uint32_t value, uint32_t min, uint32_t max) {
    return value < min ? min : (value > max ? max : value);
}
static int configure_swapchain(ZenitVkDevice *d, uint32_t width, uint32_t height, ZenitVkDiagnostic *diag) {
    int status = destroy_swapchain(d, diag);
    if (status != ZENIT_VK_OK) return status;
    VkSurfaceCapabilitiesKHR caps;
    VkResult result = d->GetPhysicalDeviceSurfaceCapabilitiesKHR(d->physical, d->surface, &caps);
    if (result != VK_SUCCESS) return surface_result(diag, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR", result);
    if (!(caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT))
        return diagnostic(diag, ZENIT_VK_NO_DEVICE, "surface transfer-destination usage unavailable", VK_SUCCESS);
    VkExtent2D extent = caps.currentExtent;
    if (extent.width == UINT32_MAX) {
        extent.width = clamp_extent(width, caps.minImageExtent.width, caps.maxImageExtent.width);
        extent.height = clamp_extent(height, caps.minImageExtent.height, caps.maxImageExtent.height);
    }
    if (!extent.width || !extent.height) return diagnostic(diag, ZENIT_VK_SURFACE_OUTDATED, "surface suspended", VK_SUCCESS);
    uint32_t format_count = 0;
    result = d->GetPhysicalDeviceSurfaceFormatsKHR(d->physical, d->surface, &format_count, NULL);
    if (result != VK_SUCCESS) return surface_result(diag, "surface format count", result);
    if (!format_count) return diagnostic(diag, ZENIT_VK_NO_DEVICE, "no surface formats", VK_SUCCESS);
    VkSurfaceFormatKHR *formats = calloc(format_count, sizeof(*formats));
    if (!formats) return diagnostic(diag, ZENIT_VK_OUT_OF_MEMORY, "surface formats", VK_ERROR_OUT_OF_HOST_MEMORY);
    result = d->GetPhysicalDeviceSurfaceFormatsKHR(d->physical, d->surface, &format_count, formats);
    int found = 0;
    for (uint32_t i = 0; i < format_count; ++i)
        if ((formats[i].format == VK_FORMAT_B8G8R8A8_UNORM || formats[i].format == VK_FORMAT_UNDEFINED) &&
            formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) found = 1;
    free(formats);
    if (result != VK_SUCCESS) return surface_result(diag, "surface formats", result);
    if (!found) return diagnostic(diag, ZENIT_VK_NO_DEVICE, "BGRA8 unorm surface unavailable", VK_SUCCESS);
    uint32_t count = caps.minImageCount + 1;
    if (caps.maxImageCount && count > caps.maxImageCount) count = caps.maxImageCount;
    /* Premultiplied first: client-side decoration paints transparent window
       corners; an opaque clear renders identically under both modes. */
    VkCompositeAlphaFlagBitsKHR alpha = VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;
    if (!(caps.supportedCompositeAlpha & alpha)) {
        const VkCompositeAlphaFlagBitsKHR alternatives[] = { VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR, VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR };
        for (unsigned i = 0; i < 3; ++i) if (caps.supportedCompositeAlpha & alternatives[i]) { alpha = alternatives[i]; break; }
    }
    VkSwapchainCreateInfoKHR info = { .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = d->surface, .minImageCount = count, .imageFormat = VK_FORMAT_B8G8R8A8_UNORM,
        .imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR, .imageExtent = extent,
        .imageArrayLayers = 1, .imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE, .preTransform = caps.currentTransform,
        .compositeAlpha = alpha, .presentMode = VK_PRESENT_MODE_FIFO_KHR, .clipped = VK_TRUE };
    result = d->CreateSwapchainKHR(d->device, &info, NULL, &d->swapchain);
    if (result != VK_SUCCESS) return surface_result(diag, "vkCreateSwapchainKHR", result);
    result = d->GetSwapchainImagesKHR(d->device, d->swapchain, &count, NULL);
    if (result != VK_SUCCESS) { status = surface_result(diag, "swapchain image count", result); goto fail; }
    if (!count) { status = diagnostic(diag, ZENIT_VK_NO_DEVICE, "empty swapchain", VK_SUCCESS); goto fail; }
    d->image_count = count;
    d->swapchain_images = calloc(count, sizeof(*d->swapchain_images));
    d->present_semaphores = calloc(count, sizeof(*d->present_semaphores));
    d->present_fences = calloc(count, sizeof(*d->present_fences));
    d->present_pending = calloc(count, sizeof(*d->present_pending));
    if (!d->swapchain_images || !d->present_semaphores || !d->present_fences || !d->present_pending) {
        status = diagnostic(diag, ZENIT_VK_OUT_OF_MEMORY, "swapchain metadata", VK_ERROR_OUT_OF_HOST_MEMORY); goto fail;
    }
    result = d->GetSwapchainImagesKHR(d->device, d->swapchain, &count, d->swapchain_images);
    if (result != VK_SUCCESS) { status = surface_result(diag, "swapchain images", result); goto fail; }
    d->image_count = count;
    VkSemaphoreCreateInfo semaphore = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    result = d->CreateSemaphore(d->device, &semaphore, NULL, &d->acquire_semaphore);
    if (result != VK_SUCCESS) { status = surface_result(diag, "create acquire semaphore", result); goto fail; }
    VkFenceCreateInfo fence = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    for (uint32_t i = 0; i < count; ++i) {
        result = d->CreateSemaphore(d->device, &semaphore, NULL, &d->present_semaphores[i]);
        if (result != VK_SUCCESS) { status = surface_result(diag, "create present semaphore", result); goto fail; }
        result = d->CreateFence(d->device, &fence, NULL, &d->present_fences[i]);
        if (result != VK_SUCCESS) { status = surface_result(diag, "create present fence", result); goto fail; }
    }
    d->extent = extent; d->swapchain_outdated = 0;
    return ZENIT_VK_OK;
fail:
    destroy_swapchain(d, NULL);
    return status;
}

static int present_image(ZenitVkDevice *d, uint32_t width, uint32_t height,
                          const float *rgba, ZenitVkTexture *source, ZenitVkDiagnostic *diag) {
    if (!d || !d->surface || (!rgba && !source) || !width || !height ||
        (source && (source->device != d || source->format != VK_FORMAT_B8G8R8A8_UNORM ||
                    source->width != width || source->height != height ||
                    source->layout == VK_IMAGE_LAYOUT_UNDEFINED)))
        return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "present arguments", VK_SUCCESS);
    if (!d->swapchain || d->swapchain_outdated || width != d->extent.width || height != d->extent.height) {
        int status = configure_swapchain(d, width, height, diag);
        if (status != ZENIT_VK_OK) return status;
    }
    if (source && (width != d->extent.width || height != d->extent.height))
        return diagnostic(diag, ZENIT_VK_SURFACE_OUTDATED, "present texture extent", VK_SUCCESS);
    uint32_t index;
    VkResult acquired = d->AcquireNextImageKHR(d->device, d->swapchain, 10000000000ull, d->acquire_semaphore, VK_NULL_HANDLE, &index);
    if (acquired != VK_SUCCESS && acquired != VK_SUBOPTIMAL_KHR) {
        if (acquired == VK_ERROR_OUT_OF_DATE_KHR) d->swapchain_outdated = 1;
        return surface_result(diag, "vkAcquireNextImageKHR", acquired);
    }
    VkCommandBuffer command = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    int submitted = 0;
    int status = ZENIT_VK_API_FAILED;
    VkResult result;
#define CHECK_PRESENT(op) do { result = (op); if (result != VK_SUCCESS) { status = surface_result(diag, #op, result); goto cleanup; } } while (0)
    if (d->present_pending[index]) {
        CHECK_PRESENT(d->WaitForFences(d->device, 1, &d->present_fences[index], VK_TRUE, 10000000000ull));
        d->present_pending[index] = 0;
        CHECK_PRESENT(d->ResetFences(d->device, 1, &d->present_fences[index]));
    }
    VkCommandBufferAllocateInfo allocation = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = d->pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    CHECK_PRESENT(d->AllocateCommandBuffers(d->device, &allocation, &command));
    VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    CHECK_PRESENT(d->BeginCommandBuffer(command, &begin));
    VkImageMemoryBarrier barrier = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = d->swapchain_images[index],
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    d->CmdPipelineBarrier(command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0, NULL, 0, NULL, 1, &barrier);
    if (source) {
        VkImageMemoryBarrier src_barrier = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT, .oldLayout = source->layout,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = source->image, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
        d->CmdPipelineBarrier(command, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, 0, NULL, 0, NULL, 1, &src_barrier);
        VkImageCopy copy = { .srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
            .dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .extent = { width, height, 1 } };
        d->CmdCopyImage(command, source->image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            d->swapchain_images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
    } else {
        VkClearColorValue color;
        memcpy(color.float32, rgba, sizeof(color.float32));
        d->CmdClearColorImage(command, d->swapchain_images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &barrier.subresourceRange);
    }
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask = 0;
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; barrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    d->CmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        0, 0, NULL, 0, NULL, 1, &barrier);
    CHECK_PRESENT(d->EndCommandBuffer(command));
    VkFenceCreateInfo fence_info = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    CHECK_PRESENT(d->CreateFence(d->device, &fence_info, NULL, &fence));
    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1, .pWaitSemaphores = &d->acquire_semaphore, .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1, .pCommandBuffers = &command,
        .signalSemaphoreCount = 1, .pSignalSemaphores = &d->present_semaphores[index] };
    CHECK_PRESENT(d->QueueSubmit(d->queue, 1, &submit, fence));
    submitted = 1;
    if (source) source->layout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    VkSwapchainPresentFenceInfoEXT present_fence = { .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_EXT,
        .swapchainCount = 1, .pFences = &d->present_fences[index] };
    VkPresentInfoKHR present = { .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .pNext = &present_fence,
        .waitSemaphoreCount = 1, .pWaitSemaphores = &d->present_semaphores[index],
        .swapchainCount = 1, .pSwapchains = &d->swapchain, .pImageIndices = &index };
    /* The present commits this extent; its viewport destination goes with it. */
    if (zenit_wayland_before_present && d->wayland_surface) zenit_wayland_before_present(d->wayland_surface, width, height);
    VkResult presented = d->QueuePresentKHR(d->queue, &present);
    if (presented == VK_SUCCESS || presented == VK_SUBOPTIMAL_KHR || presented == VK_ERROR_OUT_OF_DATE_KHR ||
        presented == VK_ERROR_SURFACE_LOST_KHR) d->present_pending[index] = 1;
    CHECK_PRESENT(d->WaitForFences(d->device, 1, &fence, VK_TRUE, 10000000000ull));
    submitted = 0;
    if (presented == VK_ERROR_OUT_OF_DATE_KHR || presented == VK_SUBOPTIMAL_KHR || acquired == VK_SUBOPTIMAL_KHR)
        d->swapchain_outdated = 1;
    status = presented == VK_SUCCESS ? diagnostic(diag, ZENIT_VK_OK, "present complete", VK_SUCCESS)
        : surface_result(diag, "vkQueuePresentKHR", presented);
cleanup:
    if (submitted) d->DeviceWaitIdle(d->device);
    if (fence) d->DestroyFence(d->device, fence, NULL);
    if (command) d->FreeCommandBuffers(d->device, d->pool, 1, &command);
    // After any error following acquire, recreate instead of reusing a possibly
    // signaled acquire semaphore or an unreleased image on the next frame.
    if (status != ZENIT_VK_OK) d->swapchain_outdated = 1;
#undef CHECK_PRESENT
    return status;
}

int zenit_vk_present_clear(ZenitVkDevice *d, uint32_t width, uint32_t height,
                           const float rgba[4], ZenitVkDiagnostic *diag) {
    return present_image(d, width, height, rgba, NULL, diag);
}
int zenit_vk_present_texture(ZenitVkDevice *d, ZenitVkTexture *texture, ZenitVkDiagnostic *diag) {
    if (!texture) return diagnostic(diag, ZENIT_VK_INVALID_ARGUMENT, "present texture", VK_SUCCESS);
    return present_image(d, texture->width, texture->height, NULL, texture, diag);
}
