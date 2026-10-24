//! Native driver instantiation of shared Linux ownership.
const shared = @import("../linux/surface.zig").For(@import("renderer_device.zig"), @import("renderer_resources.zig"));
pub const NativeSurface = shared.NativeSurface;
pub const SurfaceUsage = shared.SurfaceUsage;
pub const PresentMode = shared.PresentMode;
pub const AlphaMode = shared.AlphaMode;
pub const SurfaceConfiguration = shared.SurfaceConfiguration;
pub const Surface = shared.Surface;
pub const SurfaceTexture = shared.SurfaceTexture;
