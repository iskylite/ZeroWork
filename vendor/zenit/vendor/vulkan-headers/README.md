# Vulkan headers

Pinned Khronos Vulkan-Headers 1.4.315 (`VK_HEADER_VERSION` 315), copied from
the installed official Homebrew `vulkan-headers` package. This subset contains
`vulkan_core.h`, `vk_platform.h`, and the video declarations included by core.
Source: https://github.com/KhronosGroup/Vulkan-Headers/tree/v1.4.315

These are compile-time declarations only. The Linux backend dynamically opens
the guest system's `libvulkan.so.1`; it does not bundle a loader or GPU driver.
See each header's SPDX identifier and LICENSE.md.
