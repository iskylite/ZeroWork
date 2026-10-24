// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! ControlShell styles: size recipe and variant coloring (YSS, shared source for
//! Button/Input/Select/DatePicker),
//! plus theme-computed metrics and cross-dimension geometry (literal Zig: line_height = font_size *
//! multiplier is arithmetic, read theme).
//! Business logic (controlShell() / ControlShellConfig / slot assembly) in mod.zig; variant enum
//! from mod.zig.
const ui = @import("../../ui.zig");
const core = @import("../../core.zig");
const theme = core.theme;
const Sizing = core.Sizing;
const Padding = core.Padding;
const ConditionalStyle = core.ConditionalStyle;
const recipe_mod = @import("../../recipe.zig");
const mod = @import("mod.zig");
const ControlVariant = mod.ControlVariant;

/// Size recipe: outer padding (vertical fractional is optical widget tweak) / radius / gap,
/// text font-size and line-height, icon size. Size tiers are recipe not theme category;
/// gap, font-size, radius, icon size still draw design-system token.
pub const SizeRecipe = ui.sva(.{ .slots = .{ .root, .content, .icon, }, .base = .{ .content = .{ .line_height = ui.tokenRef(.line_height, "tight"), }, }, .variants = .{ .size = .{ .xs = .{ .root = .{ .padding = .{ .y = 2.5, .x = ui.tokenRef(.space, "space150") }, .corner_radius = ui.tokenRef(.radius, "md"), .gap = ui.tokenRef(.space, "space100"), }, .content = .{ .font_size = ui.tokenRef(.font_size, "sm"), }, .icon = .{ .width = ui.tokenRef(.size, "xs"), }, }, .sm = .{ .root = .{ .padding = .{ .y = 4.5, .x = ui.tokenRef(.space, "space200") }, .corner_radius = ui.tokenRef(.radius, "lg"), .gap = ui.tokenRef(.space, "space100"), }, .content = .{ .font_size = ui.tokenRef(.font_size, "sm"), }, .icon = .{ .width = ui.tokenRef(.size, "sm"), }, }, .md = .{ .root = .{ .padding = .{ .y = 7.25, .x = ui.tokenRef(.space, "space300") }, .corner_radius = ui.tokenRef(.radius, "xl"), .gap = ui.tokenRef(.space, "space150"), }, .content = .{ .font_size = ui.tokenRef(.font_size, "lg"), }, .icon = .{ .width = ui.tokenRef(.size, "md"), }, }, .lg = .{ .root = .{ .padding = .{ .y = 10, .x = ui.tokenRef(.space, "space400") }, .corner_radius = ui.tokenRef(.radius, "xxl"), .gap = ui.tokenRef(.space, "space200"), }, .content = .{ .font_size = ui.tokenRef(.font_size, "xl"), }, .icon = .{ .width = ui.tokenRef(.size, "lg"), }, }, }, }, .defaults = .{ .size = .md, }, });

/// Variant coloring: background / text / weight / border, hover/press/disabled states.
/// primary reads theme button-primary-* token (custom theme swaps brand), hover/press derived from
/// background.
pub const Tone = ui.cva(.{ .variants = .{ .kind = .{ .primary = .{ .background = ui.tokenRef(.color, "button-primary-bg"), .color = ui.tokenRef(.color, "button-primary-fg"), .font_weight = 600, .border_width = 0, .border_color = ui.Color.TRANSPARENT, ._hover = .{ .background = ui.mix(ui.tokenRef(.color, "button-primary-bg"), ui.Color.hex(0x000000), 0.35), }, ._active = .{ .background = ui.mix(ui.tokenRef(.color, "button-primary-bg"), ui.Color.hex(0xffffff), 0.1), }, ._disabled = .{ .background = ui.tokenRef(.color, "bg-secondary"), .color = ui.tokenRef(.color, "fg-tertiary"), }, }, .secondary = .{ .background = ui.tokenRef(.color, "bg-primary"), .color = ui.tokenRef(.color, "fg-primary"), .font_weight = 500, .border_width = 1, .border_color = ui.tokenRef(.color, "border"), ._hover = .{ .background = ui.tokenRef(.color, "bg-hover"), .border_color = ui.tokenRef(.color, "border-strong"), }, ._active = .{ .background = ui.tokenRef(.color, "bg-active"), }, ._disabled = .{ .opacity = 0.5, }, }, .ghost = .{ .color = ui.tokenRef(.color, "fg-secondary"), .font_weight = 500, ._hover = .{ .background = ui.tokenRef(.color, "bg-hover"), }, ._active = .{ .background = ui.tokenRef(.color, "bg-active"), }, ._disabled = .{ .opacity = 0.5, }, }, .danger = .{ .background = ui.tokenRef(.color, "danger"), .color = ui.tokenRef(.color, "status-fg"), .font_weight = 600, ._hover = .{ .background = ui.tokenRef(.color, "danger-hover"), }, ._active = .{ .background = ui.mix(ui.tokenRef(.color, "danger-hover"), ui.Color.hex(0x000000), 0.1), }, ._disabled = .{ .opacity = 0.5, }, }, .link = .{ .color = ui.tokenRef(.color, "accent"), .font_weight = 500, ._disabled = .{ .opacity = 0.5, }, }, .field = .{ .background = ui.tokenRef(.color, "input-bg"), .color = ui.tokenRef(.color, "fg-primary"), .font_weight = 400, .border_width = 1, .border_color = ui.tokenRef(.color, "border-strong"), ._hover = .{ .border_color = ui.tokenRef(.color, "border-focus"), }, ._disabled = .{ .background = ui.tokenRef(.color, "bg-secondary"), .color = ui.tokenRef(.color, "fg-secondary"), .border_color = ui.tokenRef(.color, "separator"), }, }, }, }, .defaults = .{ .kind = .secondary, }, });

pub const ControlSize = SizeRecipe.Dim(.size);
pub const ControlMetrics = struct {
    /// Text font size
    font_size: f32,
    /// Line-height multiplier (relative to font_size). Line height px = font_size * line_height
    line_height: f32,
    /// Radius
    radius: f32,
    /// Top/bottom padding (outer height = padding_y * 2 + line-height)
    padding_y: f32,
    /// Left/right padding
    padding_h: f32,
    /// Left padding when leading icon (top/bottom/right stay padding_y / padding_h)
    padding_leading_icon: f32,
    /// Icon size (<= line height)
    icon_size: f32,
    /// Icon-to-text gap
    gap: f32,

    /// Line height (px) = font_size * line_height
    pub fn lineHeightPx(self: ControlMetrics) f32 {
        return self.font_size * self.line_height;
    }

    /// Outer height (padding_y * 2 + line-height) derived from metrics.
    /// Read-only for measure/assert/position calc, **don't** write back to style.height;
    /// height from layout fit.
    pub fn derivedHeight(self: ControlMetrics) f32 {
        return self.padding_y * 2 + self.lineHeightPx();
    }
};

/// Measurement adapter for controls sharing the shell's line-box contract.
/// The recipe is the sole owner of the size mapping.
pub fn metrics(t: *const theme.ThemeTokens, size: ControlSize) ControlMetrics {
    const root = SizeRecipe.Slot(.root).resolve(.{ .size = size }, t).base;
    const content = SizeRecipe.Slot(.content).resolveText(.{ .size = size }, .{}, t);
    const icon = SizeRecipe.Slot(.icon).resolve(.{ .size = size }, t).base;
    return .{
        .font_size = content.font_size,
        .line_height = content.line_height,
        .radius = root.corner_radius.?,
        .padding_y = root.padding.?.top,
        .padding_h = root.padding.?.right,
        .padding_leading_icon = @max(0, root.padding.?.left - t.tokens.space.space50),
        .icon_size = @min(icon.width.?.px, content.font_size * content.line_height),
        .gap = root.gap.?,
    };
}

// ============================================================================
// ControlShellRecipe: recipe() unifying variant x size and 5 dimensions
//
// Resolve order: base < variant < derived < external override
// Variant dimension owns: background / border / text_color / font_weight / interaction states
// Derived owns cross-dimension geometry: padding / radius / gap (height/width always fit,
//   height set by content) = f(size, pill, icon_only, leading_icon) (a single-dimension
//   resolver cannot express this)
// ============================================================================
pub const ControlShellRecipe = recipe_mod.recipe(struct {
    pub const Variants = struct {
        variant: ControlVariant = .secondary,
        size: ControlSize = .md,
        /// pill mode affects radius, dimension three
        pill: bool = false,
        /// icon_only affects padding, dimension four
        icon_only: bool = false,
        /// leading_icon affects padding, dimension five
        leading_icon: bool = false,
    };

    /// Coloring only from YSS Tone recipe (shared with Button)
    pub const variants = .{
        .variant = struct {
            fn resolve(v: ControlVariant, t: *const theme.ThemeTokens) ConditionalStyle {
                return Tone.resolve(.{ .kind = Tone.toDim(@FieldType(Tone.Variants, "kind"), v) }, t);
            }
        }.resolve,
    };

    /// Cross-dimension geometry only; must not touch background (pollutes bgColors tri-state
    /// color).
    /// size/pill/icon_only/leading_icon have no independent resolver, all combined here.
    ///
    /// **No height/width pixel output**: outer height = padding_y * 2 + line box (line_height),
    /// from layout
    /// fit (line box min height is set in controlShell() per metrics.lineHeightPx()). icon_only:
    /// four-side padding = padding_y + (line_height - icon_size) / 2, icon slot min icon_size
    /// square
    /// -> outer = icon_size + 2*pad = line_height + 2*padding_y: naturally square, text-control
    /// height.
    pub fn derived(v: Variants, t: *const theme.ThemeTokens) ConditionalStyle {
        const m = metrics(t, v.size);
        const pad: Padding = if (v.icon_only)
            Padding.all(m.padding_y + (m.lineHeightPx() - m.icon_size) / 2)
        else if (v.leading_icon)
            Padding{
                .top = m.padding_y,
                .right = m.padding_h,
                .bottom = m.padding_y,
                .left = m.padding_leading_icon,
            }
        else
            Padding.symmetric(m.padding_y, m.padding_h);
        return .{
            .base = .{
                .padding = pad,
                .corner_radius = if (v.pill) 999 else m.radius,
                .height = Sizing{ .fit = .{} },
                .width = Sizing{ .fit = .{} },
                .gap = m.gap,
            },
        };
    }
});

//# yix-map styles.yss
