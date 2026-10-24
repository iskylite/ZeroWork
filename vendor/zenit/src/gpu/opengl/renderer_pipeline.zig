//! OpenGL instantiation of the shared Linux renderer contracts.
const shared = @import("../linux/renderer_pipeline.zig").For(@import("device.zig"));
pub const ShaderFunction = shared.ShaderFunction;
pub const VertexAttributeDescriptor = shared.VertexAttributeDescriptor;
pub const VertexBufferLayoutDescriptor = shared.VertexBufferLayoutDescriptor;
pub const BlendFactor = shared.BlendFactor;
pub const BlendOperation = shared.BlendOperation;
pub const BlendState = shared.BlendState;
pub const RenderPipelineDescriptor = shared.RenderPipelineDescriptor;
pub const Binding = shared.Binding;
pub const Owner = shared.Owner;
pub const RenderPipeline = shared.RenderPipeline;
pub const createRenderPipeline = shared.createRenderPipeline;
