//! Tabs style layer, TabsSlotRecipe + variant x size spec table.
//!
//! Business logic (TabsRuntime/Builder/mount/event/before_render) in mod.zig; this file has only
//! style declarations. TabsVariant/TabsSize are public API, left in mod.zig, accessed via cycle
//! import.
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;
const ConditionalStyle = core.ConditionalStyle;
const StyleOverride = core.StyleOverride;
const recipe_mod = @import("../../recipe.zig");
const mod = @import("mod.zig");
const TabsVariant = mod.TabsVariant;
const TabsSize = mod.TabsSize;

// Tabs slot recipe: 5 slots: root, tab, highlight, badge, close.
//
// All styles converge here: variant resolver manages color/font-weight/highlight appearance,
// derived manages geometry from variant x size combinations (padding/radius/gap/font_size). Active
// state is not a separate slot but .selected condition on tab slot; consumers call
// `slots.tab.resolve(.{ .is_selected = is_active })`. mount/buildTab only consume resolve results,
// no longer each holding style decisions.

pub const TabsSlotRecipe = recipe_mod.slotRecipe(struct {
    pub const Slots = struct {
        root: ConditionalStyle = .{},
        /// Tab item (active state uses .selected condition field).
        tab: ConditionalStyle = .{},
        /// Slide indicator following active tab (underline / pill white-background slider / tab
        /// light background).
        highlight: ConditionalStyle = .{},
        /// Numeric badge.
        badge: ConditionalStyle = .{},
        /// Close button.
        close: ConditionalStyle = .{},
    };

    pub const Variants = struct {
        variant: TabsVariant = .underline,
        size: TabsSize = .md,
    };

    /// Size/variant-agnostic static component styles.
    pub fn base(t: *const theme.ThemeTokens) Slots {
        return .{
            .badge = .{ .base = .{
                .height = .{ .px = 16 },
                .background = t.tokens.color.accent,
                .padding = Padding.symmetric(0, 6),
                .border = .{ .radius = 8 },
                .justify = .center,
                .align_items = .center,
                .text_color = t.tokens.color.button_primary_fg,
                .font_size = 10,
            } },
            .close = .{ .base = .{
                .width = .{ .px = 16 },
                .height = .{ .px = 16 },
                .border = .{ .radius = 2 },
                .justify = .center,
                .align_items = .center,
                .text_color = t.tokens.color.fg_secondary,
                .font_size = 12,
            } },
        };
    }

    pub const variants = .{
        .variant = struct {
            fn resolve(v: TabsVariant, t: *const theme.ThemeTokens) Slots {
                return switch (v) {
                    .underline => .{
                        .root = .{},
                        .tab = .{ .base = .{
                            .text_color = t.tokens.color.fg_secondary,
                            .font_weight = 500,
                        }, .selected = .{
                            .text_color = t.tokens.color.fg_primary,
                            .font_weight = 600,
                        }, .hover = .{ .text_color = t.tokens.color.fg_primary } },
                        // 2px accent bar (height fixed, width/horizontal offset track active tab
                        // each frame).
                        .highlight = .{ .base = .{
                            .height = .{ .px = 2 },
                            .background = t.tokens.color.accent,
                        } },
                    },
                    .pill => .{
                        .root = .{ .base = .{
                            .background = t.tokens.color.bg_secondary,
                        } },
                        .tab = .{ .base = .{
                            .text_color = t.tokens.color.fg_secondary,
                            .font_weight = 500,
                        }, .selected = .{
                            .text_color = t.tokens.color.fg_primary,
                            .font_weight = 600,
                        } },
                        // White slider + precise shadow.
                        .highlight = .{ .base = .{
                            .background = t.tokens.color.bg_primary,
                            .shadow = .{ .color = Color.rgba(0, 0, 0, 15), .blur = 2, .offset_x = 0, .offset_y = 1 },
                        } },
                    },
                    .tab => .{
                        .root = .{},
                        .tab = .{ .base = .{
                            .text_color = t.tokens.color.fg_secondary,
                            .font_weight = 500,
                        }, .selected = .{
                            .text_color = t.tokens.color.accent,
                            .font_weight = 600,
                        } },
                        .highlight = .{ .base = .{
                            .background = t.tokens.color.accent_subtle,
                        } },
                    },
                };
            }
        }.resolve,
    };

    /// Cross-dimension geometry: all padding/radius/gap/font_size from variant x size combinations
    /// here. Produce only geometry fields, never touch background (see recipe.zig derived
    /// contract).
    pub fn derived(v: Variants, _: *const theme.ThemeTokens) Slots {
        const item_geo = StyleOverride{
            .padding = itemPadding(v.variant, v.size),
            .gap = itemGap(v.variant, v.size),
            .font_size = tabFontSize(v.size),
        };
        return .{
            .root = .{ .base = .{
                .padding = rootPadding(v.variant, v.size),
                .corner_radius = rootCornerRadius(v.variant, v.size),
                .gap = rootGap(v.variant, v.size),
            } },
            // Selected condition doesn't change geometry, one base suffices.
            .tab = .{ .base = item_geo },
            .highlight = .{ .base = .{
                .corner_radius = highlightRadius(v.variant, v.size),
            } },
        };
    }
});

// Tabs independent spec table, 4 sizes (xs/sm/md/lg).
//
// Consumed only by TabsSlotRecipe.derived (tabIconSize exception: icon size not a StyleOverride
// field, consumed directly by buildTab). Component logic must not call directly.

/// Tab text font size (slightly smaller than ControlSize.fontSize).
pub fn tabFontSize(size: TabsSize) f32 {
    return switch (size) {
        .xs => 11,
        .sm => 11,
        .md => 13,
        .lg => 14,
    };
}

// ── Underline variant spec ──

pub fn underlineItemPadding(size: TabsSize) Padding {
    return switch (size) {
        .xs => Padding.symmetric(3.5, 6),
        .sm => Padding.symmetric(5.5, 8),
        .md => Padding.symmetric(8, 10),
        .lg => Padding.symmetric(11.5, 14),
    };
}

// ── Pill variant spec ──

pub fn pillOuterPadding(size: TabsSize) f32 {
    return switch (size) {
        .xs => 2,
        .sm => 2,
        .md => 3,
        .lg => 4,
    };
}

pub fn pillOuterRadius(size: TabsSize) f32 {
    return switch (size) {
        .xs => 5,
        .sm => 7,
        .md => 9,
        .lg => 12,
    };
}

pub fn pillInnerPadding(size: TabsSize) Padding {
    return switch (size) {
        .xs => Padding.symmetric(1.5, 6),
        .sm => Padding.symmetric(3.5, 6),
        .md => Padding.symmetric(5, 10),
        .lg => Padding.symmetric(7.5, 14),
    };
}

pub fn pillInnerRadius(size: TabsSize) f32 {
    return switch (size) {
        .xs => 3,
        .sm => 5,
        .md => 6,
        .lg => 8,
    };
}

// ── Tab (icon) variant spec ──

pub fn tabItemPadding(size: TabsSize) Padding {
    return switch (size) {
        .xs => Padding.symmetric(3.5, 6),
        .sm => Padding.symmetric(5.5, 8),
        .md => Padding.symmetric(8, 10),
        .lg => Padding.symmetric(11, 14),
    };
}

pub fn tabIconSize(size: TabsSize) f32 {
    return switch (size) {
        .xs => 10,
        .sm => 12,
        .md => 14,
        .lg => 18,
    };
}

pub fn tabIconTextGap(size: TabsSize) f32 {
    return switch (size) {
        .xs => 4,
        .sm => 4,
        .md => 6,
        .lg => 8,
    };
}

pub fn tabCornerRadius(size: TabsSize) f32 {
    return switch (size) {
        .xs => 4,
        .sm => 6,
        .md => 8,
        .lg => 10,
    };
}

// -- Container-level spec --

pub fn rootPadding(variant: TabsVariant, size: TabsSize) Padding {
    return switch (variant) {
        .underline => Padding.ZERO,
        .pill => Padding.all(pillOuterPadding(size)),
        .tab => Padding.ZERO,
    };
}

pub fn rootCornerRadius(variant: TabsVariant, size: TabsSize) f32 {
    return switch (variant) {
        .underline => 0,
        .pill => pillOuterRadius(size),
        .tab => 0,
    };
}

pub fn rootGap(variant: TabsVariant, size: TabsSize) f32 {
    return switch (variant) {
        .underline => 0,
        .pill => 2,
        .tab => switch (size) {
            .xs => 2,
            .sm => 2,
            .md => 4,
            .lg => 4,
        },
    };
}

/// Tab item padding per variant.
pub fn itemPadding(variant: TabsVariant, size: TabsSize) Padding {
    return switch (variant) {
        .underline => underlineItemPadding(size),
        .pill => pillInnerPadding(size),
        .tab => tabItemPadding(size),
    };
}

/// Item gap per variant.
pub fn itemGap(variant: TabsVariant, size: TabsSize) f32 {
    return switch (variant) {
        .underline, .pill => switch (size) {
            .xs => 4,
            .sm => 4,
            .md => 6,
            .lg => 8,
        },
        .tab => tabIconTextGap(size),
    };
}

/// highlight_box corner radius.
pub fn highlightRadius(variant: TabsVariant, size: TabsSize) f32 {
    return switch (variant) {
        .underline => 2,
        .pill => pillInnerRadius(size),
        .tab => tabCornerRadius(size),
    };
}
