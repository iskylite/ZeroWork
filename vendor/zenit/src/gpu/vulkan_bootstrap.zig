//! Native Vulkan exports within the canonical GPU module. Acceptance tools
//! and production renderers share the selected backend and descriptor types.
const native = @import("vulkan/device.zig");
pub const Handle = native.Handle;
pub const DeviceInfo = native.DeviceInfo;
pub const Diagnostic = native.Diagnostic;
pub const Error = native.Error;
pub const check = native.check;
pub const Device = native.Device;
pub const resources = native.resources;
pub const pipeline = native.pipeline;
pub const shaders = native.shaders;
pub const renderer_resources = native.renderer_resources;
pub const renderer_pipeline = @import("vulkan/renderer_pipeline.zig");

pub const renderer_commands = @import("vulkan/renderer_commands.zig");
pub const renderer_device = @import("vulkan/renderer_device.zig");
