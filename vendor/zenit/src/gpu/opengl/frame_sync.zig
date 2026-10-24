//! Native driver instantiation of shared Linux ownership.
const shared = @import("../linux/frame_sync.zig").For(@import("renderer_commands.zig"));
pub const FrameSync = shared.FrameSync;
