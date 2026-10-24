//! BackgroundExtension -- SwiftUI `backgroundExtensionEffect()` (macOS 26).
//!
//! Native measurement (scripts/glass_native_model/native_bg_extension.swift, 8 40pt color stripes,
//! 150pt safe area on left): the view mirrors along safe-area edges and fills the entire extensible
//! region (including window margins beyond the frame); only the view's own safe-area interior is
//! blurred (band transitions 10-90% wide 22-25pt, sigma ~9.5pt), the mirror beyond the frame stays
//! sharp. Non-safe edges (top/bottom) don't extend.
//!
//! Zenit has no safe-area concept: the caller provides leading/trailing extend widths; the builder
//! builds two copies of content, the second flipped horizontally and placed outside the content
//! edge (no clipping, overflow is a sharp mirror), with the extension region capped by `.blur_only`
//! glass for blur.
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const glass_box = @import("../glass_box/mod.zig");

pub const Builder = *const fn (scope: *Scope, cx: *Cx) anyerror!*Node;

pub const BackgroundExtensionProps = struct {
    /// Content size (mirror copy same size as content)
    width: f32,
    height: f32,
    /// Left/right extend region width (determined by safe area in SwiftUI)
    leading: f32 = 0,
    trailing: f32 = 0,
    /// Extend region blur radius (pipeline blur radius, logical px): calibrated to native sigma ≈
    /// 9.5pt
    blur_radius: f32 = blur_radius_native,
};

/// Pipeline blur radius 15.5 (edge-clamping capture) -> band transition 10-90% wide 24.6-24.9pt,
/// native 24.9-25.7pt (GlassExtension story and native_bg_extension.swift same geometry
/// calibration).
pub const blur_radius_native: f32 = 15.5;

pub fn BackgroundExtension(scope: *Scope, cx: *Cx, props: BackgroundExtensionProps, build: Builder) !*Node {
    const a = cx.allocator;
    const root = try box(cx, .{
        .width = .{ .px = props.leading + props.width + props.trailing },
        .height = .{ .px = props.height },
        .position = .relative,
    }, .{});
    errdefer cx.freeNode(root);
    root.meta.ownership.meta.component_name = "BackgroundExtension";

    // Mirror copy colocated with content, horizontal flip around the edge touching extend region:
    // flipped copy lands exactly in extend region. Don't place copy in extend region then flip
    // around center -- visibility culling uses pre-transform rect, child nodes far from content get
    // incorrectly culled (measured orange/red lines disappearing).
    const sides = [_]struct { extent: f32, origin_x: f32 }{
        .{ .extent = props.leading, .origin_x = 0 },
        .{ .extent = props.trailing, .origin_x = 1 },
    };
    // Mirror copy (drawn first, under content and blur layer)
    for (sides) |side| {
        if (side.extent <= 0) continue;
        const copy = try core.adoptChild(cx, a, root, try build(scope, cx));
        copy.style.position = .absolute;
        const ext = try copy.style.ensureExtFallible(a);
        ext.inset = .{ .left = .{ .px = props.leading }, .top = .{ .px = 0 } };
        ext.scale_x = -1;
        ext.transform_origin = .{ .x = .{ .percent = side.origin_x }, .y = .{ .percent = 0.5 } };
        copy.behavior.interaction.a11y = null;
        (try copy.style.ensureExtFallible(a)).hit_roles = .{};
    }
    // Content
    const content = try core.adoptChild(cx, a, root, try build(scope, cx));
    content.style.position = .absolute;
    (try content.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = props.leading }, .top = .{ .px = 0 } };
    // Blur only view's own extend region
    const regions = [_][2]f32{ .{ 0, props.leading }, .{ props.leading + props.width, props.trailing } };
    for (regions) |rg| {
        if (rg[1] <= 0 or props.blur_radius <= 0) continue;
        const blur = try glass_box.GlassBox(.{
            .width = rg[1],
            .height = props.height,
            .shape = .{ .rounded = 0 },
            .material = .blur_only,
            .blur_radius = props.blur_radius,
            .drop_shadow = false,
            .padding = core.Padding.all(0),
            .body_gap = 0,
        }).mount(scope, cx);
        blur.style.position = .absolute;
        (try blur.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = rg[0] }, .top = .{ .px = 0 } };
        _ = try core.adoptChild(cx, a, root, blur);
    }
    return root;
}
