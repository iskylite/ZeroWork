/// Animation module: Zenit UI animation system.
///
/// Architecture layers:
///
/// Presets (fadeIn/slideUp/scaleIn/shake/...)          preset animations
/// Hooks (useAnimation/useTimeline/...)                scope-declarative
/// animateNode (node command-based animations)         node property animation
/// Timeline + Position (GSAP-style arrangement)         time line
/// AnimationController (unified playback control)       controller
/// AnimationManager (global management)                 global
/// Tween / Spring / Transition / Keyframes              low-level drivers
/// Easing (31 presets + CubicBezier)                    easing functions
///
/// Design principles:
/// 1. Frame-driven: each frame call tick(delta_time)
/// 2. Declarative + imperative: TransitionSlots auto-transition + animateNode manual control
/// 3. Composable: Timeline arrangement + Position relative positioning
const std = @import("std");

// -- Low-level driver --

pub const tween = @import("tween.zig");
pub const Tween = tween.Tween;
pub const TweenConfig = tween.TweenConfig;

pub const spring = @import("spring.zig");
pub const Spring = spring.Spring;
pub const SpringConfig = spring.SpringConfig;
pub const SpringPreset = spring.SpringPreset;

pub const easing = @import("easing.zig");
pub const Easing = easing.Easing;
pub const CubicBezierParams = easing.CubicBezierParams;

pub const transition = @import("transition.zig");
pub const Transition = transition.Transition;
pub const TransitionConfig = transition.TransitionConfig;

pub const animated_value = @import("animated_value.zig");
pub const AnimatedValue = animated_value.AnimatedValue;

pub const animated_color = @import("animated_color.zig");
pub const AnimatedColor = animated_color.AnimatedColor;
pub const AnimatedColorConfig = animated_color.AnimatedColorConfig;

pub const keyframes = @import("keyframes.zig");
pub const Keyframe = keyframes.Keyframe;
pub const KeyframeAnimation = keyframes.KeyframeAnimation;

// -- Controller --

pub const controller = @import("controller.zig");
pub const AnimationController = controller.AnimationController;
pub const PlayState = controller.PlayState;

// -- Timeline --

pub const timeline_mod = @import("timeline.zig");
pub const Timeline = timeline_mod.Timeline;
pub const Position = timeline_mod.Position;
pub const TimelineEntry = timeline_mod.TimelineEntry;

// -- Node animation --

pub const node_animator = @import("node_animator.zig");
pub const NodeAnimations = node_animator.NodeAnimations;
pub const AnimatableProp = node_animator.AnimatableProp;
pub const AnimateConfig = node_animator.AnimateConfig;
pub const animateNode = node_animator.animateNode;

// -- Global management --

pub const manager = @import("manager.zig");
pub const AnimationManager = manager.AnimationManager;

// ── Hooks ──

pub const anim_hooks = @import("anim_hooks.zig");
pub const useAnimation = anim_hooks.useAnimation;
pub const useSpringAnimation = anim_hooks.useSpringAnimation;
pub const useTimeline = anim_hooks.useTimeline;

// -- Presets --

pub const presets = @import("presets.zig");

// -- Compatible types --

/// Animation state
pub const AnimationState = enum {
    idle,
    running,
    paused,
    completed,
};

test {
    std.testing.refAllDecls(@This());
}
