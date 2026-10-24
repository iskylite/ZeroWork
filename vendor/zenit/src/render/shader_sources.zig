//! Shader programs selected with the GPU backend at compile time.
const gpu = @import("gpu");
pub const blur: []const u8 = if (gpu.is_direct3d or gpu.backend_kind == .vulkan or gpu.backend_kind == .opengl) gpu.Backend.shaders.blur else @embedFile("shaders/blur.metal");
pub const composite: []const u8 = if (gpu.is_direct3d or gpu.backend_kind == .vulkan or gpu.backend_kind == .opengl) gpu.Backend.shaders.composite else @embedFile("shaders/composite.metal");
pub const path: []const u8 = if (gpu.is_direct3d or gpu.backend_kind == .vulkan or gpu.backend_kind == .opengl) gpu.Backend.shaders.path else @embedFile("shaders/path.metal");
pub const image: []const u8 = if (gpu.is_direct3d or gpu.backend_kind == .vulkan or gpu.backend_kind == .opengl) gpu.Backend.shaders.image else @embedFile("shaders/image.metal");
pub const damage_clear: []const u8 = if (gpu.is_direct3d or gpu.backend_kind == .vulkan or gpu.backend_kind == .opengl) gpu.Backend.shaders.damage_clear else @embedFile("shaders/damage_clear.metal");
pub const icon: []const u8 = if (gpu.is_direct3d or gpu.backend_kind == .vulkan or gpu.backend_kind == .opengl) gpu.Backend.shaders.icon else @embedFile("shaders/icon.metal");
pub const text: []const u8 = if (gpu.is_direct3d or gpu.backend_kind == .vulkan or gpu.backend_kind == .opengl) gpu.Backend.shaders.text else @embedFile("shaders/text.metal");
pub const sdf: []const u8 = if (gpu.is_direct3d or gpu.backend_kind == .vulkan or gpu.backend_kind == .opengl) gpu.Backend.shaders.sdf else @embedFile("shaders/sdf_primitives.metal");
pub const glass: []const u8 = if (gpu.is_direct3d or gpu.backend_kind == .vulkan or gpu.backend_kind == .opengl) gpu.Backend.shaders.glass else @embedFile("shaders/glass.metal");
