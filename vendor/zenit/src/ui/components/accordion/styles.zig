//! Accordion style layer, AccordionItemRecipe(variant) and header/body geometry contract
//! (zenit-styling-revamp).
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;
const Border = core.Border;
const ConditionalStyle = core.ConditionalStyle;
const recipe_mod = @import("../../recipe.zig");
const AccordionVariant = @import("mod.zig").AccordionVariant;

pub const AccordionItemRecipe = recipe_mod.recipe(struct {
    pub const Variants = struct {
        variant: AccordionVariant = .default,
    };

    pub const variants = .{
        .variant = struct {
            fn resolve(v: AccordionVariant, t: *const theme.ThemeTokens) ConditionalStyle {
                return switch (v) {
                    .default => .{
                        .base = .{
                            .background = t.tokens.color.bg_secondary,
                            .corner_radius = t.tokens.radius.xl,
                        },
                    },
                    .outline => .{
                        .base = .{
                            .background = Color.TRANSPARENT,
                            .border = Border{ .width = 1, .color = t.tokens.color.fg_tertiary, .radius = t.tokens.radius.xl },
                        },
                    },
                    .ghost => .{
                        .base = .{
                            .background = Color.TRANSPARENT,
                        },
                    },
                };
            }
        }.resolve,
    };
});

// ── Named static styles (header / title / body / chevron geometry contract) ──
//
// body left indent = chevron size + header gap + header left padding (aligns title start),
// three quantities are part of same geometry contract, declared centrally here.

pub const accordion_header_padding = Padding.symmetric(14, 20);
pub const accordion_header_gap: f32 = 12;
pub const accordion_chevron_size: f32 = 16;

pub fn accordionHeaderStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .align_items = .center,
        .padding = accordion_header_padding,
        .gap = accordion_header_gap,
        .cursor = .pointer,
    };
}

pub fn accordionTitleText(is_expanded: bool, t: *const theme.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_primary,
        .font_size = t.tokens.font_size.lg,
        .font_weight = if (is_expanded) 600 else 500,
        .line_height = 1.538,
    };
}

pub fn accordionBodyStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    const body_left = accordion_chevron_size + accordion_header_gap + accordion_header_padding.left;
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .padding = .{ .top = 0, .right = accordion_header_padding.right, .bottom = 16, .left = body_left },
    };
}

/// item container border color on hover (harmonized with variant background)
pub fn accordionHoverBorderColor(item_bg: Color, t: *const theme.ThemeTokens) Color {
    return Color.lerp(t.tokens.color.fg_tertiary, item_bg, 0.5);
}
