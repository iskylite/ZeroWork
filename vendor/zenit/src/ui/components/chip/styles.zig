//! Chip styling layer: ChipRecipe + shell variant mapping
//!
//! Chip is based on ControlShell: chip-specific style decisions (variant background/text/border
//! override + hover target color) live here; geometry comes from ControlShellRecipe (pill mode).
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const ConditionalStyle = core.ConditionalStyle;
const recipe_mod = @import("../../recipe.zig");
const mod = @import("mod.zig");
const control_shell = @import("../control_shell/mod.zig");

/// ChipLook -> ControlShell base variant
pub fn shellVariant(v: mod.ChipLook) control_shell.ControlVariant {
    return switch (v) {
        .default => .secondary,
        .active => .primary,
        .outline => .ghost,
        .disabled => .secondary,
    };
}

/// Chip's own recipe: base overrides shell base, hover targets interaction color.
///
/// Notes:
/// - text_color supplies label/icon/close color; the shell root node renders no text, so this
///   field is inert for the shell;
/// - hover is gated by component-level readonly/disabled (null on mount suppresses);
///   the recipe only declares the target color;
/// - disabled variant sets `.disabled = .{ .opacity = 1.0 }`: Chip's disabled state uses
///   color, not opacity (overrides shell secondary's 0.5 default).
pub const ChipRecipe = recipe_mod.recipe(struct {
    pub const Variants = struct {
        variant: mod.ChipLook = .default,
    };

    pub const variants = .{
        .variant = struct {
            fn resolve(v: mod.ChipLook, t: *const theme.ThemeTokens) ConditionalStyle {
                return switch (v) {
                    .default => .{
                        .base = .{
                            .background = t.tokens.color.bg_primary,
                            .text_color = t.tokens.color.fg_primary,
                            .border = .{ .width = 1, .color = t.tokens.color.border_strong },
                        },
                        .hover = .{ .background = t.tokens.color.bg_secondary },
                    },
                    .active => .{
                        .base = .{
                            .background = t.tokens.color.accent,
                            .text_color = t.tokens.color.button_primary_fg,
                            .border = .{ .width = 1, .color = Color.lerp(t.tokens.color.accent, t.tokens.color.fg_primary, 0.18) },
                        },
                        .hover = .{ .background = Color.lerp(t.tokens.color.accent, Color.WHITE, 0.1) },
                    },
                    .outline => .{
                        .base = .{
                            .background = t.tokens.color.bg_secondary,
                            .text_color = t.tokens.color.fg_primary,
                            .border = .{ .width = 1, .color = t.tokens.color.border_strong },
                        },
                        .hover = .{ .background = t.tokens.color.bg_tertiary },
                    },
                    .disabled => .{
                        .base = .{
                            .background = t.tokens.color.bg_secondary,
                            .text_color = t.tokens.color.fg_secondary,
                            .border = .{ .width = 1, .color = t.tokens.color.separator },
                        },
                        .disabled = .{ .opacity = 1.0 },
                    },
                };
            }
        }.resolve,
    };
});
