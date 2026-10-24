const node_mod = @import("node.zig");
const types = @import("types.zig");

const Node = node_mod.Node;
const Transform2D = types.Transform2D;

pub const TransformBuildOptions = struct {
    include_scale: bool = true,
    include_rotation: bool = false,
};

pub fn buildNodeLocalTransform(node: *const Node, options: TransformBuildOptions) Transform2D {
    // NOTE: retained_scene also called in hit-test path, hit_runtime.buildRecursive relies on
    // transformRect
    // and node.rect strictly matching (World rect post-sticky/translate has small delta after
    // syncScrollbarFrame).
    // Even epoch==0 fallback can't fully guarantee behavior equivalence here. session 27 + session
    // 29 both tried and reverted.
    // Preserve the owner World read and its epoch fallback.
    const rect = node.rectFromWorldOrFallback();
    const origin = node.style.transform_origin().resolve(rect.w, rect.h);

    var transform = Transform2D.fromRectWithOrigin(
        rect.x + node.style.translate_x + node.frame_state.frame_local.runtime.sticky.x,
        rect.y + node.style.translate_y + node.frame_state.frame_local.runtime.sticky.y,
        rect.w,
        rect.h,
        if (options.include_scale) node.style.scale_x() else 1.0,
        if (options.include_scale) node.style.scale_y() else 1.0,
        origin.x,
        origin.y,
    );

    // Rotation remains opt-in so callers can stage affine adoption incrementally.
    if (options.include_rotation and @abs(node.style.rotate()) > 0.0001) {
        transform = transform.mul(
            Transform2D.rotation(node.style.rotate(), origin.x, origin.y),
        );
    }

    return transform;
}

pub fn buildNodeWorldTransform(node: *const Node, parent_transform: Transform2D, options: TransformBuildOptions) Transform2D {
    return parent_transform.mul(buildNodeLocalTransform(node, options));
}

/// Owner-thread queries without a retained transform ID use the same local
/// composition as render traversal, including nonsemantic ancestors.
pub fn buildAncestorWorldTransform(node: *const Node, options: TransformBuildOptions) Transform2D {
    var result = Transform2D.identity();
    var current: ?*const Node = node;
    while (current) |ancestor| : (current = ancestor.parent) {
        result = buildNodeLocalTransform(ancestor, options).mul(result);
    }
    return result;
}
