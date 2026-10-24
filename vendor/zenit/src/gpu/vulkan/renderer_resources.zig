//! Vulkan instantiation of the shared Linux renderer contracts.
const shared = @import("../linux/renderer_resources.zig").For(@import("device.zig"));
pub const gpu = shared.gpu;
pub const vk = shared.vk;
pub const ResourceError = shared.ResourceError;
pub const Error = shared.Error;
pub const Context = shared.Context;
pub const BufferOwner = shared.BufferOwner;
pub const Buffer = shared.Buffer;
pub const TextureOwner = shared.TextureOwner;
pub const Texture = shared.Texture;
pub const TextureBinding = shared.TextureBinding;
pub const TextureView = shared.TextureView;
pub const SamplerOwner = shared.SamplerOwner;
pub const Sampler = shared.Sampler;
pub const RecordingReadback = shared.RecordingReadback;
