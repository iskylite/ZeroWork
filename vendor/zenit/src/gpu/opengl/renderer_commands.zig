//! OpenGL instantiation of the shared Linux renderer contracts.
const shared = @import("../linux/renderer_commands.zig").For(@import("device.zig"));
pub const Queue = shared.Queue;
pub const CommandEncoder = shared.CommandEncoder;
pub const RenderPass = shared.RenderPass;
pub const BlitPass = shared.BlitPass;
pub const CommandBuffer = shared.CommandBuffer;
