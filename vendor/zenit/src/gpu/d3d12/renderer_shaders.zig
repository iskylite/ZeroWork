//! Explicit HLSL ports of the shared renderer's Metal shader programs.
pub const blur = @embedFile("shaders/blur.hlsl");
pub const composite = @embedFile("shaders/composite.hlsl");
pub const path = @embedFile("shaders/path.hlsl");
pub const image = @embedFile("shaders/image.hlsl");
pub const damage_clear = @embedFile("shaders/damage_clear.hlsl");
pub const icon = @embedFile("shaders/icon.hlsl");
pub const text = @embedFile("shaders/text.hlsl");
pub const sdf = @embedFile("shaders/sdf_primitives.hlsl");
pub const glass = @embedFile("shaders/glass.hlsl");
