/// Animation Hooks: declarative animation creation bound to Scope
///
/// All resources created by hooks are automatically freed with Scope lifecycle.
///
/// Usage:
/// ```zig
/// const anim = @import("animation/anim_hooks.zig");
///
/// // Scope-bound tween animation
/// const ctrl = try anim.useAnimation(scope, .{
///     .from = 0, .to = 100, .duration = 0.5,
/// });
/// // ctrl.value updates automatically each frame
///
/// // Scope-bound spring animation
/// const spring_ctrl = try anim.useSpringAnimation(scope, .{
///     .from = 0, .to = 100, .stiffness = 200, .damping = 20,
/// });
///
/// // Scope-bound timeline
/// const tl = try anim.useTimeline(scope);
/// try tl.add(&ctrl1, .start);
/// tl.play();
/// ```
const std = @import("std");
const ctrl_mod = @import("controller.zig");
const AnimationController = ctrl_mod.AnimationController;
const timeline_mod = @import("timeline.zig");
const Timeline = timeline_mod.Timeline;
const Easing = @import("easing.zig").Easing;

/// Get Scope type (defer resolution to avoid circular dependencies)
const Scope = @import("../reactive/scope.zig").Scope;

/// Tween animation configuration
pub const UseAnimationConfig = struct {
    from: f32 = 0,
    to: f32 = 1,
    duration: f32 = 0.3,
    easing: Easing = .ease_out_quad,
    delay: f32 = 0,
    loops: u32 = 1,
    yoyo: bool = false,
    auto_play: bool = true,
};

/// Create a Scope-bound Tween animation controller
pub fn useAnimation(scope: *Scope, config: UseAnimationConfig) !*AnimationController {
    const ctrl = try scope.allocator.create(AnimationController);
    errdefer scope.allocator.destroy(ctrl);
    ctrl.* = AnimationController.initTween(.{
        .from = config.from,
        .to = config.to,
        .duration = config.duration,
        .easing = config.easing,
        .delay = config.delay,
    });
    ctrl.loops = config.loops;
    ctrl.yoyo = config.yoyo;

    ctrl.lifetime_scope = scope;
    ctrl.scope_lifetime = try ctrl_mod.ScopeLifetime.create(scope);
    errdefer ctrl.releaseLifetime();
    try scope.registerResource(@ptrCast(ctrl), destroyController);

    if (config.auto_play) ctrl.play();
    return ctrl;
}

/// Spring animation configuration
pub const UseSpringConfig = struct {
    from: f32 = 0,
    to: f32 = 1,
    stiffness: f32 = 170,
    damping: f32 = 26,
    mass: f32 = 1,
    auto_play: bool = true,
};

/// Create a Scope-bound Spring animation controller
pub fn useSpringAnimation(scope: *Scope, config: UseSpringConfig) !*AnimationController {
    const ctrl = try scope.allocator.create(AnimationController);
    errdefer scope.allocator.destroy(ctrl);
    ctrl.* = AnimationController.initSpring(.{
        .from = config.from,
        .to = config.to,
        .stiffness = config.stiffness,
        .damping = config.damping,
        .mass = config.mass,
    });

    ctrl.lifetime_scope = scope;
    ctrl.scope_lifetime = try ctrl_mod.ScopeLifetime.create(scope);
    errdefer ctrl.releaseLifetime();
    try scope.registerResource(@ptrCast(ctrl), destroyController);

    if (config.auto_play) ctrl.play();
    return ctrl;
}

/// Create a Scope-bound Timeline
///
/// Scope cleanup calls Timeline.deinit, which automatically unregisters it
/// from every AnimationManager before releasing the allocation. Registered
/// managers and timelines must stay at stable addresses until detached.
pub fn useTimeline(scope: *Scope) !*Timeline {
    const tl = try scope.allocator.create(Timeline);
    errdefer scope.allocator.destroy(tl);
    tl.* = Timeline.init(scope.allocator);
    tl.lifetime_scope = scope;

    try scope.registerResource(@ptrCast(tl), destroyTimeline);

    return tl;
}

// -- Cleanup functions --

fn destroyController(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const ctrl: *AnimationController = @ptrCast(@alignCast(ptr));
    if (ctrl.scope_lifetime) |lifetime| lifetime.retire();
    ctrl.releaseLifetime();
    allocator.destroy(ctrl);
}

fn destroyTimeline(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const tl: *Timeline = @ptrCast(@alignCast(ptr));
    tl.deinit();
    allocator.destroy(tl);
}
