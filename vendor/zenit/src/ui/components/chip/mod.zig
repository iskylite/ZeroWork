/// Chip Component
///
/// Tag component for filters, multi-select tags, category tags, etc. Built on
/// ControlShell, reusing its background animation / focus ring / corner radius.
///
/// Features:
/// - 3 sizes: xs(20), sm(24), md(32), maps ControlSize
/// - 4 variants: default, active, outline, disabled
/// - pill-shaped corner (radius=999 via ControlShell pill mode)
/// - optional icon + closeable
/// - read-only by default (readonly=true); hover/click/focus only when readonly=false
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const control_shell = @import("../control_shell/mod.zig");
const controlShell = control_shell.controlShell;
const styles = @import("styles.zig");

/// Chip style recipe (re-exported: external consumers take from mod, not directly from styles.zig)
pub const ChipRecipe = styles.ChipRecipe;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Source = reactive.Source;
const Handler = core.Handler;
const hooks = @import("../../hooks.zig");
const bind_mod = @import("../../bind.zig");
const svg_assets = @import("../../svg_assets.zig");
const view = @import("../../view.zig");

// ============================================================================
// Type definitions
// ============================================================================

/// Chip size, maps ControlSize xs/sm/md
pub const ChipSize = enum {
    xs,
    sm,
    md,

    pub fn controlSize(self: ChipSize) control_shell.ControlSize {
        return switch (self) {
            .xs => .xs,
            .sm => .sm,
            .md => .md,
        };
    }
};

/// Chip appearance variant (structural config). Selected / disabled are states; see `selected` /
/// `disabled`
pub const ChipVariant = enum {
    default,
    outline,
};

/// recipe dimension: combined appearance + state visual outcome
pub const ChipLook = enum {
    default,
    active,
    outline,
    disabled,

    fn of(variant: ChipVariant, selected: bool, disabled: bool) ChipLook {
        if (disabled) return .disabled;
        if (selected) return .active;
        return switch (variant) {
            .default => .default,
            .outline => .outline,
        };
    }
};

// ============================================================================
// Chip properties + Builder
// ============================================================================

pub const ChipProps = struct {
    label: Source([]const u8),
    size: ChipSize = .sm,
    variant: ChipVariant = .default,
    /// selected (filter chip active state): fill color; AT reads as selected
    selected: Source(bool) = .{ .value = false },
    disabled: Source(bool) = .{ .value = false },
    icon_asset: ?svg_assets.Asset = null,
    closable: bool = false,
    /// structural config: read-only chip has no interaction (not focusable, click unresponsive)
    readonly: bool = true,
    on_click: ?Handler(void) = null,
    on_close: ?Handler(void) = null,
};

/// create Chip: `W.Chip(.{ .label = "Open", .selected = filter_open, .readonly = false, .on_click =
/// ... })`
pub fn Chip(props: anytype) ChipBuilder {
    return .{ .props = reactive.props.coerce(ChipProps, props) };
}

/// Chip runtime: view = f(selected, disabled); click gated by runtime disabled state
const ChipRuntime = struct {
    selected: Source(bool),
    disabled: Source(bool),
    variant: ChipVariant,
    on_click: ?Handler(void),
    on_close: ?Handler(void),
    node: *Node,
    label_node: *Node,
    icon_node: ?*Node = null,
    close_icon: ?*Node = null,
    anim: ?*hooks.AnimBgState,
    readonly: bool,
    tokens: *const theme.ThemeTokens,
    is_disabled: bool = false,

    fn apply(self: *ChipRuntime, sel: bool, dis: bool) void {
        const t = self.tokens;
        self.is_disabled = dis;
        const cs = styles.ChipRecipe.resolve(.{ .variant = ChipLook.of(self.variant, sel, dis) }, t);
        const bg = cs.base.background orelse Color.TRANSPARENT;
        const interactive = !self.readonly and !dis;
        if (self.anim) |anim| {
            // hover animation is owned by AnimBgState; when non-interactive, hover and normal backgrounds
            // are the same color, so there is no feedback.
            const hover_bg = if (cs.hover) |h| h.background orelse bg else bg;
            anim.setColors(bg, if (interactive) hover_bg else bg);
        } else {
            self.node.setBackground(bg);
        }
        if (cs.base.border) |b| {
            self.node.style.border.color = b.color;
            self.node.style.border.width = b.width;
        }
        const fg = cs.base.text_color orelse t.tokens.color.fg_primary;
        if (self.label_node.getText()) |old| {
            var txt = old;
            txt.color = fg;
            self.label_node.setText(txt);
        }
        if (self.icon_node) |n| _ = n.setTint(fg);
        if (self.close_icon) |n| _ = n.setTint(fg);
        if (!self.readonly) {
            self.node.setFocusable(!dis);
            self.node.style.cursor = if (dis) .not_allowed else .pointer;
        }
        if (self.node.behavior.interaction.a11y) |*a| {
            a.selected = sel;
            a.disabled = dis;
        }
        self.node.markRenderDirty();
    }

    fn viewEffect(self: *ChipRuntime) void {
        self.apply(self.selected.read(true), self.disabled.read(true));
    }

    fn click(ctx: *anyopaque) void {
        const self: *ChipRuntime = @ptrCast(@alignCast(ctx));
        if (self.is_disabled) return;
        if (self.on_click) |h| h.invoke();
    }

    fn close(ctx: *anyopaque) void {
        const self: *ChipRuntime = @ptrCast(@alignCast(ctx));
        if (self.is_disabled) return;
        if (self.on_close) |h| h.invoke();
    }
};

pub const ChipBuilder = struct {
    props: ChipProps,

    pub fn mount(self: ChipBuilder, scope: *Scope, cx: *Cx) !*Node {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        const t = cx.tokens;
        const p = self.props;
        const sz = p.size.controlSize();
        const sel0 = p.selected.read(false);
        const dis0 = p.disabled.read(false);
        // interactivity: readonly is structural; disabled is state (dynamic disable shell builds
        // interactive, gate at runtime)
        const may_interact = !p.readonly and (!p.disabled.isStatic() or !dis0);
        const look0 = ChipLook.of(p.variant, sel0, dis0);

        // Chip's own styles all come from ChipRecipe (base override + hover target color + disabled
        // override)
        const cs = styles.ChipRecipe.resolve(.{ .variant = look0 }, t);

        // text color, label/icon/close share recipe base text_color
        const text_color: Color = cs.base.text_color orelse t.tokens.color.fg_primary;
        const metrics = control_shell.metrics(t, sz);

        // runtime allocated before shell: close button click handler declared with slot content,
        // needs its address first. Guarded here before shell scope (scope created when shell
        // mounts).
        const rt = try scope.allocator.create(ChipRuntime);
        var rt_adopted = false;
        errdefer if (!rt_adopted) scope.allocator.destroy(rt);
        rt.* = .{
            .selected = p.selected,
            .disabled = p.disabled,
            .variant = p.variant,
            .on_click = p.on_click,
            .on_close = p.on_close,
            .node = undefined,
            .label_node = undefined,
            .anim = null,
            .readonly = p.readonly,
            .tokens = t,
            .is_disabled = dis0,
        };

        // build unified base via ControlShell: icon slot = leading icon, content slot = label,
        // append slot = close
        const close_size: core.Sizing = .{ .px = metrics.icon_size - 2 };
        const shell = try controlShell(.{
            .size = sz,
            .variant = styles.shellVariant(look0),
            .disabled = dis0 and p.disabled.isStatic(),
            .pill = true,
            .leading_icon = p.icon_asset != null,
            .style = cs.base,
            .hover_style = if (may_interact) cs.hover else null,
            .disabled_style = if (look0 == .disabled) cs.disabled else null,
            .interactive = may_interact,
            .focus_ring = may_interact,
            .cursor = if (may_interact and !dis0) .pointer else .default,
        }, .{
            .icon = if (p.icon_asset) |asset| view.capture(&rt.icon_node, view.icon(.{
                .style = .{ .width = .{ .px = metrics.icon_size }, .height = .{ .px = metrics.icon_size } },
                .tint = text_color,
            }, asset)) else null,
            // node holds text copy, a11y label points to it
            .content = view.capture(&rt.label_node, view.text(.{ .style = core.TextStyle{
                .color = text_color,
                .font_size = metrics.font_size,
                .line_height = metrics.line_height,
                .font_weight = 500,
            } }, p.label.peek())),
            .content_style = core.BoxStyle{ .width = .{ .fit = .{} } },
            .append = if (p.closable) view.box(.{
                .style = core.BoxStyle{
                    .width = close_size,
                    .height = close_size,
                    .justify = .center,
                    .align_items = .center,
                    .cursor = if (!p.readonly) .pointer else null,
                },
                .a11y = .{ .role = .button, .label = "Remove" },
                .on_click = if (!p.readonly and p.on_close != null) core.Cx.simpleHandler(ChipRuntime.close, rt) else null,
            }, view.capture(&rt.close_icon, view.icon(.{
                .style = .{ .width = close_size, .height = close_size },
                .tint = text_color,
            }, svg_assets.common.x_close))) else null,
        }, scope, cx);

        const node = shell.node;
        errdefer cx.freeNode(node);
        const chip_scope = shell.scope;
        rt_adopted = true;
        try chip_scope.adoptResource(@ptrCast(rt), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                alloc.destroy(@as(*ChipRuntime, @ptrCast(@alignCast(ptr))));
            }
        }.destroy);
        rt.node = node;
        rt.anim = shell.anim_bg;
        node.meta.ownership.meta.component_name = "Chip";
        reactive.checkBorrow(chip_scope, p.label);
        reactive.checkBorrow(chip_scope, p.selected);
        reactive.checkBorrow(chip_scope, p.disabled);
        // selected state is visual expression of fill color; AT can only read it via selected
        node.behavior.interaction.a11y = .{
            .role = if (p.readonly) .listitem else .button,
            .selected = sel0,
            .disabled = dis0,
            .label = rt.label_node.getText().?.content,
        };
        node.style.justify = .center;
        if (!p.label.isStatic()) try bind_mod.bindTextLabel(cx, chip_scope, p.label, rt.label_node, node);

        if (!p.readonly and p.on_click != null) {
            node.behavior.events.on_click = core.Cx.simpleHandler(ChipRuntime.click, rt);
        }

        // selected / disabled: create effect only if one will change
        if (!p.selected.isStatic() or !p.disabled.isStatic()) {
            try chip_scope.createEffect(rt, ChipRuntime.viewEffect);
        }

        return node;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Chip: basic creation" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try Chip(.{ .label = "Tag" }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, node);

    try std.testing.expectEqualStrings("Chip", node.meta.ownership.meta.component_name.?);
    // sm -> ControlSize.sm -> height=24
    ctx.layout();
    // height fitted by padding_y * 2 + line_height (no longer style.height px)
    try std.testing.expectEqual(@as(f32, 24), node.rectFromWorldOrFallback().h);
}

test "Chip: 反复 mount/free 不泄漏 World element slot（未用 slot 走 freeNode）" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Cycle = struct {
        fn run(c: *Cx, s: *Scope, r: *Node) !void {
            const sub = try s.childScope();
            const n = try Chip(.{ .label = "x" }).mount(sub, c); // no icon, not closeable: both slots unused
            try r.appendChild(c.allocator, n);
            c.detachChild(r, n);
            c.freeNode(n);
            sub.dispose();
        }
    };
    try Cycle.run(ctx, scope, root);
    const baseline = ctx.world.elements.count();
    var i: usize = 0;
    while (i < 20) : (i += 1) try Cycle.run(ctx, scope, root);
    try std.testing.expectEqual(baseline, ctx.world.elements.count());
}

test "Chip: with icon and close" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try Chip(.{
        .label = "Filter",
        .icon_asset = svg_assets.common.search,
        .closable = true,
        .size = .md,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, node);

    // md -> ControlSize.md -> height=32
    ctx.layout();
    // height fitted by padding_y * 2 + line_height (no longer style.height px)
    try std.testing.expectEqual(@as(f32, 32), node.rectFromWorldOrFallback().h);
}

test "Chip: xs size" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try Chip(.{
        .label = "Mini",
        .size = .xs,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, node);

    // xs -> ControlSize.xs -> height=20
    ctx.layout();
    // height fitted by padding_y * 2 + line_height (no longer style.height px)
    try std.testing.expectEqual(@as(f32, 20), node.rectFromWorldOrFallback().h);
}

test "Chip: disabled variant" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try Chip(.{
        .label = "Disabled",
        .disabled = true,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, node);

    try std.testing.expectEqual(@as(f32, 1.0), node.getOpacity());
    try std.testing.expectEqual(thematicColor(ctx.tokens.tokens.color.bg_secondary), thematicColor(node.getBackground()));
    try std.testing.expectEqual(thematicColor(ctx.tokens.tokens.color.separator), thematicColor(node.style.border.color));
}

fn thematicColor(color: Color) u32 {
    return @bitCast(color);
}

test "Chip: readonly by default disables hover interaction" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try Chip(.{ .label = "Readonly by default" }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, node);

    try std.testing.expect(node.behavior.events.on_hover == null);
    try std.testing.expectEqual(core.CursorShape.default, node.style.cursor);
}

test "Chip: readonly false enables hover interaction" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try Chip(.{
        .label = "Interactive",
        .readonly = false,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, node);

    try std.testing.expect(node.behavior.events.on_hover != null);
    try std.testing.expectEqual(core.CursorShape.pointer, node.style.cursor);
}

test "Chip: render emits background and label text" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(240, 80);

    const root = try box(ctx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 80 },
        .background = ctx.tokens.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try Chip(.{
        .label = "Filter",
        .variant = .default,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, node);

    ctx.layout();
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    var saw_bg = false;
    var saw_label = false;
    for (commands) |cmd| if (cmd.isFillRect()) {
        const r = cmd;
        if (Color.eql(r.color.toColor(), ctx.tokens.tokens.color.bg_primary) and r.geom.w >= 40 and r.geom.h >= 20) {
            saw_bg = true;
        }
    } else if (cmd.isText()) {
        const tcmd = cmd;
        if (std.mem.eql(u8, tcmd.text_content, "Filter")) saw_label = true;
    };

    try std.testing.expect(saw_bg);
    try std.testing.expect(saw_label);
}

// styles.zig test collection, this line required; see docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// OOM sweep per allocation point; see src/ui/components/oom_sweep.zig
test "chip(closable): mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("chip(closable)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Chip(.{ .label = "chip", .closable = true, .readonly = false }).mount(scope, cx);
        }
    }.m);
}

test "Chip: selected / disabled from signals; disabled gates the click; dynamic label" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const on = try scope.createSignal(bool, false);
    const off = try scope.createSignal(bool, false);
    const name = try scope.createText("Open", .{});
    var clicks: u32 = 0;
    const node = try Chip(.{ .label = name, .selected = on, .disabled = off, .readonly = false, .on_click = ctx.on(u32, &clicks, struct {
        fn f(c: *u32) void {
            c.* += 1;
        }
    }.f) }).mount(scope, ctx);
    defer ctx.freeNode(node);
    const label = node.children.items[0].children.items[0];

    on.set(true);
    try std.testing.expect(node.behavior.interaction.a11y.?.selected);
    const active = styles.ChipRecipe.resolve(.{ .variant = .active }, ctx.tokens);
    try std.testing.expect(Color.eql(label.getText().?.color, active.base.text_color.?));

    node.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(@as(u32, 1), clicks);
    off.set(true);
    node.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(@as(u32, 1), clicks); // no response when disabled
    try std.testing.expect(!node.behavior.interaction.focusable);
    try std.testing.expect(node.behavior.interaction.a11y.?.disabled);

    name.set("Open issues");
    try std.testing.expectEqualStrings("Open issues", label.getText().?.content);
    try std.testing.expectEqual(label.getText().?.content.ptr, node.behavior.interaction.a11y.?.label.?.ptr);
}

test "chip: 动态选中 / 禁用 / 文本的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("chip(dynamic)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const on = try scope.createSignal(bool, true);
            const name = try scope.createText("Open", .{});
            return try Chip(.{ .label = name, .selected = on, .closable = true, .readonly = false, .icon_asset = svg_assets.common.search }).mount(scope, cx);
        }
    }.m);
}
