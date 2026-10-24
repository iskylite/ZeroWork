//! Select Headless, Radix-style decoupled component
//!
//! This directory is the sole Select implementation.
//!
//! Features:
//! - Slot-based (render_trigger/render_item) + SelectSlotRecipe in recipe.zig
//! - virtualize=true connects VirtualList, 1k+ options without Node explosion
//! - Data flow: value/open are Model, options/disabled are Source (interaction only suggests)
//! - Keyboard: typeahead/arrow keys/PageUp/PageDown/Home/End/Esc/Enter built-in
//!
//! File split:
//! - `state_machine.zig`: pure logic (Option/SelectState/step/Action/commit); no core/reactive
//!   dependency, bench facade direct import
//! - `mount.zig`: render mount layer (SelectHeadless/VirtualList path/slot ctx/SelectSlotRecipe
//!   default base style)
//! - `mod.zig` (this file): aggregate re-export, single entry point
//!
//! Design reference: Radix UI Select / shadcn Select / Panda CSS sva slot recipe.

const sm = @import("state_machine.zig");

// pure-logic re-exports (state machine)
pub const Option = sm.Option;
pub const OpenState = sm.OpenState;
pub const SelectState = sm.SelectState;
pub const Action = sm.Action;
pub const step = sm.step;
pub const commitSelection = sm.commitSelection;

/// select_headless main render entry point (mount.zig). Uses Popover + default item list to mount
/// state machine to *Node tree.
pub const mount = @import("mount.zig");
pub const SelectHeadless = mount.SelectHeadless;
pub const MountProps = mount.MountProps;
pub const SelectHeadlessResult = mount.SelectHeadlessResult;
pub const stateOf = mount.stateOf;

// slot / recipe / variant re-export
pub const SelectSlotRecipe = mount.SelectSlotRecipe;
pub const SelectVariant = mount.SelectVariant;
pub const SelectSize = mount.SelectSize;
pub const TriggerSlotCtx = mount.TriggerSlotCtx;
pub const ItemSlotCtx = mount.ItemSlotCtx;

// mount.zig/state_machine.zig tests were never referenced by any test block, never collected by
// test-ui (includes 3 existing tests in mount.zig). Explicitly attached.
test {
    _ = mount;
    _ = sm;
}
