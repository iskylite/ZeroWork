/// Animation and transition state check utils
/// Check whether node has active composite / opacity / transform animation or transition
const types = @import("../types.zig");
const node_mod = @import("../node.zig");

const Node = node_mod.Node;

// ─────────────────────────────────────────────────────────────────────────────
// Transition property classification
// ─────────────────────────────────────────────────────────────────────────────

pub fn transitionPropIsComposite(prop: types.TransitionProp) bool {
    return switch (prop) {
        .opacity, .translate_x, .translate_y, .scale_x, .scale_y, .rotate => true,
        else => false,
    };
}

pub fn transitionPropIsOpacity(prop: types.TransitionProp) bool {
    return prop == .opacity;
}

pub fn transitionPropIsTransform(prop: types.TransitionProp) bool {
    return switch (prop) {
        .translate_x, .translate_y, .scale_x, .scale_y, .rotate => true,
        else => false,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Active Transition checking
// ─────────────────────────────────────────────────────────────────────────────

pub fn hasActiveCompositeTransition(node: *Node) bool {
    const slots = node.frame_state.frame_local.runtime.transitions orelse return false;
    for (slots.slots[0..slots.count]) |slot| {
        if (slot.active and transitionPropIsComposite(slot.prop)) return true;
    }
    return false;
}

pub fn hasActiveOpacityTransition(node: *Node) bool {
    const slots = node.frame_state.frame_local.runtime.transitions orelse return false;
    for (slots.slots[0..slots.count]) |slot| {
        if (slot.active and transitionPropIsOpacity(slot.prop)) return true;
    }
    return false;
}

pub fn hasActiveTransformTransition(node: *Node) bool {
    const slots = node.frame_state.frame_local.runtime.transitions orelse return false;
    for (slots.slots[0..slots.count]) |slot| {
        if (slot.active and transitionPropIsTransform(slot.prop)) return true;
    }
    return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Active NodeAnimation checking
// ─────────────────────────────────────────────────────────────────────────────

pub fn hasActiveOpacityNodeAnimation(node: *Node) bool {
    const anims = node.frame_state.frame_local.runtime.commands orelse return false;
    for (anims.entries[0..anims.count]) |entry| {
        if (entry.prop == .opacity) return true;
    }
    return false;
}

pub fn hasActiveTransformNodeAnimation(node: *Node) bool {
    const anims = node.frame_state.frame_local.runtime.commands orelse return false;
    for (anims.entries[0..anims.count]) |entry| {
        switch (entry.prop) {
            .translate_x, .translate_y, .scale_x, .scale_y, .rotate => return true,
            else => {},
        }
    }
    return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Combined checking (transition + node_animation + manual)
// ─────────────────────────────────────────────────────────────────────────────

pub fn hasActiveCompositeAnimation(node: *Node) bool {
    if (node.frame_state.frame_local.runtime.linger.composite > 0) return true;
    if (node.frame_state.state_bits.flags.manual_transform_animation_active or node.frame_state.state_bits.flags.manual_opacity_animation_active) return true;
    if (hasActiveCompositeTransition(node)) return true;
    const anims = node.frame_state.frame_local.runtime.commands orelse return false;
    for (anims.entries[0..anims.count]) |entry| {
        switch (entry.prop) {
            .opacity, .translate_x, .translate_y, .scale_x, .scale_y, .rotate => return true,
            else => {},
        }
    }
    return false;
}

pub fn hasActiveOpacityAnimation(node: *Node) bool {
    if (node.frame_state.frame_local.runtime.linger.opacity > 0) return true;
    return node.frame_state.state_bits.flags.manual_opacity_animation_active or hasActiveOpacityTransition(node) or hasActiveOpacityNodeAnimation(node);
}

pub fn hasActiveTransformAnimation(node: *Node) bool {
    if (node.frame_state.frame_local.runtime.linger.transform > 0) return true;
    return node.frame_state.state_bits.flags.manual_transform_animation_active or hasActiveTransformTransition(node) or hasActiveTransformNodeAnimation(node);
}
