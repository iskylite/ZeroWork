//! Vulkan instantiation of the shared Linux renderer contracts.
const shared = @import("../linux/renderer_shaders.zig").For(@import("device.zig"), @import("vulkan_ui_shaders"), "zenit-vulkan:");
pub const blur = shared.blur;
pub const composite = shared.composite;
pub const path = shared.path;
pub const image = shared.image;
pub const damage_clear = shared.damage_clear;
pub const icon = shared.icon;
pub const text = shared.text;
pub const sdf = shared.sdf;
pub const glass = shared.glass;
pub const ShaderFunction = shared.ShaderFunction;
pub const ShaderModule = shared.ShaderModule;
