/// UI interaction primitives
///
/// Interaction layer helpers independent of components/, don't produce Nodes just route events.
pub const range_hover = @import("range_hover.zig");
pub const RangeHoverRegistry = range_hover.RangeHoverRegistry;
pub const RangeHoverRegion = range_hover.RangeHoverRegion;
pub const RangeRect = range_hover.RangeRect;
pub const RangeId = range_hover.RangeId;

/// Continuous pointer drag primitive within window (docs/DRAG_INTERACTION_DESIGN.md).
/// New events only exposed via ui.interaction.drag.Event complete name, strictly separate
/// from existing native drop ui.events.DragEvent.
pub const drag = @import("drag.zig");

const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}
