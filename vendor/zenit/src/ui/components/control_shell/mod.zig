/// ControlShell: unified base layout function.
///
/// Provides a three-zone node structure for Button/Input/Select:
///   root (row, border, background, padding)
///   +-- icon_slot     (fit, icon/spinner)
///   +-- content_slot  (grow, text/input/label; Button overrides to fit)
///   +-- append_slot   (fit, chevron/clear)
///
/// Callers pass slot content (ui.view elements); the shell builds one tree and returns the root
/// and each slot node (see controlShell).
const std = @import("std");
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const BoxStyle = core.BoxStyle;
const Color = core.Color;
const Sizing = core.Sizing;
const Padding = core.Padding;
const Border = core.Border;
const CursorShape = core.CursorShape;
const StyleOverride = core.StyleOverride;
const ConditionalStyle = core.ConditionalStyle;
const Scope = core.Scope;
const theme = core.theme;
const hooks = @import("../../hooks.zig");
const recipe_mod = @import("../../recipe.zig");

/// Unified control variants per UniPost spec
///
/// | Style     | Background          | Text color          | Border        | Weight |
/// |-----------|---------------------|---------------------|--------------:|-------:|
/// | Primary   | $--text-primary     | $--text-inverse     | none          |    600 |
/// | Secondary | $--bg (#FFF)        | $--text-primary     | $--border 1px |    500 |
/// | Ghost     | transparent         | $--text-secondary   | none          |    500 |
/// | Link      | transparent         | $--primary          | none          |    500 |
pub const ControlVariant = enum {
    primary,
    secondary,
    ghost,
    danger,
    link,
    /// Input/Select shared input appearance: light background + border.
    field,
};

pub const ControlSize = styles.ControlSize;
pub const ControlMetrics = styles.ControlMetrics;
pub const metrics = styles.metrics;

// Component style and size contract unified in styles.yss, exported at entry.
const styles = @import("_styles.yss.zig");
pub const ControlShellRecipe = styles.ControlShellRecipe;

/// ControlShell config.
pub const ControlShellConfig = struct {
    size: ControlSize = .md,
    variant: ControlVariant = .secondary,
    disabled: bool = false,
    /// Has left icon (affects padding).
    leading_icon: bool = false,
    /// Icon-only, no text (affects padding).
    icon_only: bool = false,

    // -- Unified style override (new API, recommended) --
    /// Default state style override.
    style: StyleOverride = .{},
    /// Hover state style override.
    hover_style: ?StyleOverride = null,
    /// Pressed state style override.
    pressed_style: ?StyleOverride = null,
    /// Disabled state style override.
    disabled_style: ?StyleOverride = null,

    /// Enable hover/pressed background animation.
    interactive: bool = true,
    /// Enable focus ring.
    focus_ring: bool = true,
    /// Cursor style.
    cursor: CursorShape = .pointer,
    /// Pill mode (full radius 999).
    pill: bool = false,
    /// Root semantic tag (DatePicker trigger is .button, Input input is .input).
    tag: core.ElementTag = .box,

    /// Resolve full ConditionalStyle: ControlShellRecipe.resolve() merges variant x size x pill x
    /// icon_only x leading_icon -> external style/hover_style/pressed_style/disabled_style last
    /// override.
    pub fn resolvedConditionalStyle(self: ControlShellConfig, t: *const theme.ThemeTokens) ConditionalStyle {
        var cs = ControlShellRecipe.resolve(.{
            .variant = self.variant,
            .size = self.size,
            .pill = self.pill,
            .icon_only = self.icon_only,
            .leading_icon = self.leading_icon,
        }, t);

        // External prop override (highest priority).
        return cs.override(.{
            .style = self.style,
            .hover_style = self.hover_style,
            .pressed_style = self.pressed_style,
            .disabled_style = self.disabled_style,
        });
    }
};

/// ControlShell return: root node and each slot node (exists only if declared at mount).
pub const ControlShellResult = struct {
    /// Root node (container with border/background/padding).
    node: *Node,
    /// Left icon slot; absent if slots omits .icon or is null.
    icon_slot: ?*Node = null,
    /// Center content slot; absent if slots omits .content or is null.
    content_slot: ?*Node = null,
    /// Right append slot; absent if slots omits .append or is null.
    append_slot: ?*Node = null,
    /// Shell scope (tied to root, same lifetime).
    scope: *Scope,
    /// AnimBgState reference (runtime color control).
    anim_bg: ?*hooks.AnimBgState,

    /// `ui.view` entry: `view.capture(&shell, ControlShell(config, slots))` places shell in
    /// declaration tree.
    pub fn viewParts(self: ControlShellResult) view.ViewParts {
        return .{ .root = self.node };
    }
};

fn syncGroupedControlShell(node: *Node) void {
    const scope = node.meta.ownership.scope.scope orelse return;
    const corner = node.style.corner_radius() orelse return;
    const radii = corner.resolve4();
    const is_uniform = radii[0] == radii[1] and
        radii[1] == radii[2] and
        radii[2] == radii[3];
    const ext = node.style.ensureExtPanic(scope.allocator);

    node.style.border.radius = 0;
    ext.hit_shape = .auto;
    // Non-uniform attached corners should not re-enter the uniform rounded-clip path.
    ext.clip_shape = if (is_uniform) .auto else .none;
}

/// Create the unified three-slot control base. Slot content is declared by the caller at mount
/// time (`slots` is an anonymous struct, all fields optional):
///
/// ```zig
/// const shell = try controlShell(config, .{
///     .icon = if (asset) |a| view.icon(.{ ... }, a) else null, // null = skip icon slot (no gap)
///     .content = view.text(.{ ... }, label),                   // any ui.view child (including
///     tuple)
///     .append = {},                                            // `{}` = create empty slot
///     .content_style = BoxStyle{ .width = .{ .fit = .{} } },   // overlay default slot style
/// }, scope, cx);
/// ```
///
/// Slot presence is decided statically at mount: an omitted field, value `null`, or optional
/// value null skips the slot; other values (including `{}`) create the slot and mount the value as
/// slot children. The shell builds root and slots in one ui.view tree (failure rolls back
/// entirely), creates no empty slots, and callers need not reclaim unused slots. For runtime
/// dynamic content, declare the location as a persistent child container
/// (e.g. Button's spinner container), then `view.append` / update inside it.
pub fn controlShell(config: ControlShellConfig, slots: anytype, scope: *Scope, cx: *Cx) !ControlShellResult {
    return mountShell(config, slots, scope, cx);
}

/// Builder form of `controlShell`: can be used directly as `ui.view` child (`view.capture(&res,
/// ControlShell(config, slots))`).
pub fn ControlShell(config: ControlShellConfig, slots: anytype) ControlShellBuilder(@TypeOf(slots)) {
    return .{ .config = config, .slots = slots };
}

const slot_fields = [_][]const u8{ "icon", "content", "append", "icon_style", "content_style", "append_style" };

pub fn ControlShellBuilder(comptime Slots: type) type {
    comptime checkSlots(Slots);
    return struct {
        config: ControlShellConfig,
        slots: Slots,

        pub fn mount(self: @This(), scope: *Scope, cx: *Cx) !ControlShellResult {
            return mountShell(self.config, self.slots, scope, cx);
        }
    };
}

fn checkSlots(comptime Slots: type) void {
    if (@typeInfo(Slots) != .@"struct")
        @compileError("controlShell: slots must be a struct literal like .{ .content = ... }, got " ++ @typeName(Slots));
    outer: for (@import("zenit_reflection").fields(Slots)) |f| {
        for (slot_fields) |a| if (std.mem.eql(u8, a, f.name)) continue :outer;
        @compileError("controlShell: unknown slot ." ++ f.name ++ " (allowed: icon, content, append, icon_style, content_style, append_style)");
    }
}

/// Slot element props (named type: slot element type must be writable at compile time).
const SlotProps = struct { style: BoxStyle };

/// Slot child element type; @TypeOf(null) when slot doesn't exist.
fn SlotChildren(comptime Slots: type, comptime name: []const u8) type {
    if (!@hasField(Slots, name)) return @TypeOf(null);
    const T = @FieldType(Slots, name);
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// Slot element: `?ref(box(SlotProps, children))`; when `asSlot(e)`, `?ref(attrs(SlotProps, e))`;
/// void when slot doesn't exist (ui.view void child emits nothing).
fn SlotElem(comptime Slots: type, comptime name: []const u8, comptime dir: ?core.Direction) type {
    const C = SlotChildren(Slots, name);
    if (C == @TypeOf(null)) return void;
    if (isAsSlot(C)) return ?view.NodeCapture(*?*Node, view.Attrs(SlotProps, C.Element));
    return ?view.NodeCapture(*?*Node, view.Box(SlotProps, C, dir));
}

fn slotElem(slots: anytype, comptime name: []const u8, comptime dir: ?core.Direction, dest: *?*Node, base: BoxStyle) SlotElem(@TypeOf(slots), name, dir) {
    const Slots = @TypeOf(slots);
    const C = SlotChildren(Slots, name);
    if (C == @TypeOf(null)) return {};
    const raw = @field(slots, name);
    const children: C = if (@typeInfo(@TypeOf(raw)) == .optional) (raw orelse return null) else raw;
    const style_name = name ++ "_style";
    var style = if (@hasField(Slots, style_name)) base.merge(slotStyle(@field(slots, style_name))) else base;
    if (comptime isAsSlot(C)) {
        if (dir) |d| style.direction = d;
        return view.capture(dest, view.attrs(SlotProps{ .style = style }, children.element));
    }
    return view.capture(dest, view.Box(SlotProps, C, dir){ .props = .{ .style = style }, .children = children });
}

/// Let a single-node element itself act as slot (slot style stacks on it, no wrapping container):
/// `.content = control_shell.asSlot(view.text(...))`. For slots with only one text, runtime uses
/// slot node as-is (SelectHeadless default trigger label: label parent is outer frame).
pub fn asSlot(element: anytype) AsSlot(@TypeOf(element)) {
    return .{ .element = element };
}

pub fn AsSlot(comptime E: type) type {
    return struct {
        element: E,
        pub const Element = E;
        pub const control_shell_as_slot = true;
    };
}

fn isAsSlot(comptime C: type) bool {
    return @typeInfo(C) == .@"struct" and @hasDecl(C, "control_shell_as_slot");
}

/// Slot style override must be BoxStyle (`.content_style = BoxStyle{ .width = .{ .fit = .{} } }`).
fn slotStyle(x: anytype) BoxStyle {
    if (@TypeOf(x) != BoxStyle)
        @compileError("controlShell: *_style slots take a core.BoxStyle value, got " ++ @typeName(@TypeOf(x)));
    return x;
}

fn mountShell(config: ControlShellConfig, slots: anytype, scope: *Scope, cx: *Cx) !ControlShellResult {
    comptime checkSlots(@TypeOf(slots));
    const my_scope = try scope.childScope();
    var scope_bound = false;
    errdefer if (!scope_bound) my_scope.dispose();
    const sz = config.size;
    const t = cx.tokens;

    // -- Recipe resolve: merges variant x size x pill x icon_only x leading_icon --
    // cs includes base/hover/active/disabled full state; no manual style splicing needed.
    const cs = config.resolvedConditionalStyle(t);
    // Take initial render state (disabled = disabled state, else base state).
    const resolved = cs.resolve(.{ .is_disabled = config.disabled });

    const size_metrics = metrics(t, sz);

    // Geometry fields (padding/radius/gap) all from recipe derived; height/width always fit. Body:
    // extract scalar (hit/clip need radius) + fold fine-grain border fields.
    const radius: f32 = resolved.corner_radius.?;
    const pad: Padding = resolved.padding.?;

    // -- Border fold: radius scalar + fine-grain border_color/border_width fold to Border --
    // Not placeholder: external override (style prop) and hover/disabled use StyleOverride fine
    // fields, merged after derived, fold only here.
    var final_border: Border = resolved.border orelse Border{};
    final_border.radius = radius;
    if (resolved.border_color) |bc| final_border.color = bc;
    if (resolved.border_width) |bw| final_border.width = bw;

    const final_background = resolved.background orelse Color.TRANSPARENT;
    const height_sizing: Sizing = resolved.height.?;
    const width_sizing: Sizing = resolved.width.?;
    const final_gap: f32 = resolved.gap.?;

    // -- Line box --
    // Outer frame height contract: padding_y x 2 + line height (font_size x line_height). All three
    // slot min-heights = line_height, control height fills naturally, empty label/pure tag/content
    // shorter than line_height don't collapse. No fixed outer height. icon_only: icon slot min
    // icon_size square (with derived icon_only padding).
    const line_box: f32 = size_metrics.lineHeightPx();

    // Root: row layout, all style from recipe resolve; radius hit/clip shape written to ext. Only
    // build declared slots: no padding gap for missing icon/append, no empty content slot when
    // icon-only. Content defaults grow (Button/Chip override to fit via content_style for justify
    // center).
    var res: ControlShellResult = .{ .node = undefined, .scope = my_scope, .anim_bg = null };
    const node = try view.render(my_scope, cx, view.row(.{
        .tag = config.tag,
        .style = BoxStyle{
            .width = width_sizing,
            .height = height_sizing,
            .background = final_background,
            .border = final_border,
            .padding = pad,
            .align_items = .center,
            .gap = final_gap,
            .cursor = resolved.cursor orelse (if (config.disabled) .not_allowed else config.cursor),
            .hit_shape = .{ .rounded_rect = radius },
            .clip_shape = .{ .rounded_rect = radius },
        },
    }, .{
        slotElem(slots, "icon", null, &res.icon_slot, .{
            .width = .{ .fit = .{} },
            .height = .{ .fit = .{} },
            .align_items = .center,
            .justify = .center,
            .min_width = if (config.icon_only) size_metrics.icon_size else null,
            .min_height = if (config.icon_only) size_metrics.icon_size else line_box,
        }),
        slotElem(slots, "content", .row, &res.content_slot, .{
            .width = .{ .grow = .{} },
            .height = .{ .fit = .{} },
            .align_items = .center,
            .min_height = line_box,
        }),
        slotElem(slots, "append", .row, &res.append_slot, .{
            .width = .{ .fit = .{} },
            .height = .{ .fit = .{} },
            .align_items = .center,
            .gap = final_gap,
            .min_height = line_box,
        }),
    }));
    res.node = node;
    errdefer cx.freeNode(node);
    try core.bindScopeToNode(my_scope, node);
    scope_bound = true;
    node.meta.per_frame.hooks.before_render.main = syncGroupedControlShell;
    // syncGroupedControlShell reads/writes **only this node's** style.border.radius / ext.hit_shape
    // / ext.clip_shape (see impl), never a descendant; guarantees no paint prefix breakage.
    // Significance: control base scattered across app (title bar/tab bar/toolbar/input), undeclared
    // breaks entire paint prefix, forces all following clean subtrees to fresh emit.
    node.frame_state.state_bits.flags.before_render_hook_affects_self_only = true;
    if (resolved.opacity) |op| node.setOpacityRaw(op);

    // Hover/pressed animation + focus ring.
    if (config.interactive and !config.disabled) {
        const colors = cs.bgColors();
        _ = try hooks.useAnimatedBackground(my_scope, cx, node, .{
            .normal = colors.normal,
            .hover = colors.hover,
            .pressed = colors.pressed,
        });
        if (node.meta.per_frame.hooks.slots.animated_bg_state) |state_ptr| {
            res.anim_bg = @ptrCast(@alignCast(state_ptr));
        }
        if (config.focus_ring) {
            try hooks.useFocusRing(my_scope, cx, node, .{});
        }
    }

    return res;
}

// ========== Tests ==========

const TestEnv = struct {
    ctx: *Cx,
    root: *Node,
    scope: *Scope,

    fn init(allocator: std.mem.Allocator) !TestEnv {
        const ctx = try Cx.init(allocator, std.testing.io);
        errdefer ctx.deinit();
        const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
        ctx.root = root;
        const scope = try Scope.init(allocator, null, ctx.owner);
        return .{ .ctx = ctx, .root = root, .scope = scope };
    }

    fn deinit(self: TestEnv) void {
        self.scope.dispose();
        self.ctx.deinit();
    }
};

test "ControlShell: basic structure" {
    const allocator = std.testing.allocator;
    const env = try TestEnv.init(allocator);
    defer env.deinit();

    // Declare only content: only content_slot under root, icon/append slots absent.
    const result = try controlShell(.{}, .{ .content = {} }, env.scope, env.ctx);
    try env.root.appendChild(allocator, result.node);

    try std.testing.expectEqual(@as(usize, 1), result.node.children.items.len);
    try std.testing.expect(result.node == result.content_slot.?.parent.?);
    try std.testing.expect(result.icon_slot == null);
    try std.testing.expect(result.append_slot == null);
}

test "ControlShell: 槽按声明建、按 icon / content / append 排序，内容挂进槽里" {
    const allocator = std.testing.allocator;
    const env = try TestEnv.init(allocator);
    defer env.deinit();

    var label: *Node = undefined;
    var extra: *Node = undefined;
    const result = try controlShell(.{}, .{
        .append = view.capture(&extra, view.box(.{}, {})),
        .content = view.capture(&label, view.text(.{}, "Label")),
        .icon = view.box(.{}, {}),
        .content_style = BoxStyle{ .width = .{ .fit = .{} } },
    }, env.scope, env.ctx);
    try env.root.appendChild(allocator, result.node);

    const kids = result.node.children.items;
    try std.testing.expectEqual(@as(usize, 3), kids.len);
    try std.testing.expect(kids[0] == result.icon_slot.?);
    try std.testing.expect(kids[1] == result.content_slot.?);
    try std.testing.expect(kids[2] == result.append_slot.?);
    try std.testing.expect(label.parent.? == result.content_slot.?);
    try std.testing.expect(extra.parent.? == result.append_slot.?);
    // content_style stacks on defaults: width -> fit, line box min-height kept.
    try std.testing.expect(result.content_slot.?.style.width == .fit);
    try std.testing.expect(result.content_slot.?.style.min_height() > 0);
}

test "ControlShell: 可选内容为 null 时不建槽（不占 gap），{} 建空槽" {
    const allocator = std.testing.allocator;
    const env = try TestEnv.init(allocator);
    defer env.deinit();

    const no_icon: ?view.Box(struct {}, void, null) = null;
    const result = try controlShell(.{}, .{ .icon = no_icon, .content = null, .append = {} }, env.scope, env.ctx);
    try env.root.appendChild(allocator, result.node);

    try std.testing.expectEqual(@as(usize, 1), result.node.children.items.len);
    try std.testing.expect(result.icon_slot == null);
    try std.testing.expect(result.content_slot == null);
    try std.testing.expect(result.append_slot.?.children.items.len == 0);
}

test "ControlShell: asSlot 让单个元素本身充当槽（槽样式叠在它上面）" {
    const allocator = std.testing.allocator;
    const env = try TestEnv.init(allocator);
    defer env.deinit();

    const result = try controlShell(.{}, .{
        .content = asSlot(view.text(.{}, "Label")),
        .content_style = BoxStyle{ .overflow_hidden = true },
    }, env.scope, env.ctx);
    try env.root.appendChild(allocator, result.node);

    const label = result.content_slot.?;
    try std.testing.expect(label.parent.? == result.node);
    try std.testing.expectEqualStrings("Label", label.getText().?.content);
    try std.testing.expect(label.style.width == .grow);
    try std.testing.expect(label.style.overflow_hidden);
    try std.testing.expect(label.style.min_height() > 0);
}

test "ControlShell: 作为 ui.view 子元素挂载" {
    const allocator = std.testing.allocator;
    const env = try TestEnv.init(allocator);
    defer env.deinit();

    var shell: ControlShellResult = undefined;
    const tree = try view.render(env.scope, env.ctx, view.col(.{}, view.capture(&shell, ControlShell(.{ .tag = .button }, .{ .content = "x" }))));
    try env.root.appendChild(allocator, tree);
    try std.testing.expect(shell.node.parent.? == tree);
    try std.testing.expect(shell.node.tag == .button);
    try std.testing.expect(shell.content_slot.?.children.items.len == 1);
}

test "ControlShell: disabled skips interaction" {
    const allocator = std.testing.allocator;
    const env = try TestEnv.init(allocator);
    defer env.deinit();

    const result = try controlShell(.{ .disabled = true }, .{ .content = {} }, env.scope, env.ctx);
    try env.root.appendChild(allocator, result.node);

    // disabled -> no anim_bg, no hover handler
    try std.testing.expect(result.anim_bg == null);
    try std.testing.expect(result.node.behavior.events.on_hover == null);
}

test "ControlShell: interactive has anim_bg" {
    const allocator = std.testing.allocator;
    const env = try TestEnv.init(allocator);
    defer env.deinit();

    const result = try controlShell(.{ .interactive = true }, .{ .content = {} }, env.scope, env.ctx);
    try env.root.appendChild(allocator, result.node);

    try std.testing.expect(result.anim_bg != null);
    try std.testing.expect(result.node.behavior.events.on_hover != null);
}

test "ControlShell: grouped non-uniform radii disable uniform clip" {
    const allocator = std.testing.allocator;
    const env = try TestEnv.init(allocator);
    defer env.deinit();

    const result = try controlShell(.{}, .{ .content = {} }, env.scope, env.ctx);
    try env.root.appendChild(allocator, result.node);

    const ext = try result.node.style.ensureExtFallible(allocator);
    ext.corner_radius = .{ .each = .{ 8, 0, 0, 8 } };

    if (result.node.meta.per_frame.hooks.before_render.main) |hook| {
        hook(result.node);
    }

    try std.testing.expectEqual(@as(f32, 0), result.node.style.border.radius);
    try std.testing.expect(result.node.style.hit_shape() == .auto);
    try std.testing.expect(result.node.style.clip_shape() == .none);
}

// styles.zig test collection; this line required (see docs/STYLING.md).
test {
    _ = @import("_styles.yss.zig");
}

// Per-allocation OOM sweep (see src/ui/components/oom_sweep.zig): all three slots declared with
// content, covers slot element + caller content rollback on any allocation failure.
test "control_shell: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("control_shell", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const r = try controlShell(.{}, .{
                .icon = view.box(.{ .style = .{ .width = .{ .px = 12 } } }, {}),
                .content = view.text(.{}, "Label"),
                .append = .{ view.box(.{}, {}), view.text(.{}, "x") },
                .content_style = BoxStyle{ .width = .{ .fit = .{} } },
            }, scope, cx);
            return r.node;
        }
    }.m);
}

test "allocation campaign: control_shell builder 形态在 ui.view 树里任意分配点失败时不泄漏" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("control_shell_view", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return try view.render(scope, cx, view.col(.{}, ControlShell(.{ .interactive = true }, .{
                .icon = view.box(.{}, {}),
                .content = view.text(.{}, "Label"),
            })));
        }
    }.m);
}
