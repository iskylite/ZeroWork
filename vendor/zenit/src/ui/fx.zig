/// fx: zenit animations / physics / transitions
///
/// Consolidates animations, elastic physics, view transitions (VTAPI-style snapshot transitions),
/// router and similar motion functionality into one namespace, separate from the component
/// library (widgets) and core (ui).
///
/// Usage:
/// ```zig
/// const ui = @import("ui");
///
/// const opacity = ui.fx.AnimatedValue(f32).init(.{ ... });
/// const tween = ui.fx.Tween.init(.{ ... });
/// const router = try ui.fx.Router.init(...);
/// ```
const animation_mod = @import("animation/mod.zig");
const physics_mod = @import("physics.zig");
const snapshot_transition_mod = @import("snapshot_transition.zig");
const timeline_profiler_mod = @import("timeline_profiler.zig");

// Tests in const-referenced files aren't collected (orphan test scanner caught
// router / snapshot_transition / timeline_profiler tests never executed)
test {
    _ = router_mod;
    _ = snapshot_transition_mod;
    _ = timeline_profiler_mod;
}
const router_mod = @import("router.zig");

// Submodule pass-through
pub const animation = animation_mod;
pub const physics = physics_mod;
pub const snapshot_transition = snapshot_transition_mod;
pub const timeline_profiler = timeline_profiler_mod;
pub const router = router_mod;

// -- Animation primitives --
pub const Tween = animation_mod.Tween;
pub const Spring = animation_mod.Spring;
pub const AnimatedValue = animation_mod.AnimatedValue;
pub const AnimatedColor = animation_mod.AnimatedColor;
pub const AnimatedColorConfig = animation_mod.AnimatedColorConfig;
pub const KeyframeAnimation = animation_mod.KeyframeAnimation;
pub const AnimationController = animation_mod.AnimationController;
pub const Timeline = animation_mod.Timeline;
pub const Position = animation_mod.Position;
pub const Easing = animation_mod.Easing;

// -- Physics --
pub const RubberBand = physics_mod.RubberBand;
pub const FadeIndicator = physics_mod.FadeIndicator;

// -- View transitions (snapshot-based view transitions) --
pub const Transition = snapshot_transition_mod.Transition;
pub const SnapshotTransition = snapshot_transition_mod.SnapshotTransition;

// -- Timeline analysis --
pub const TimelineProfiler = timeline_profiler_mod.TimelineProfiler;

// ── Router ──
pub const Router = router_mod.Router;
