//! counter_reactive stylesheet, separate from business logic (Signal / Memo / event
//! binding).
//!
//! Convention (see docs/STYLING.md "Object syntax"):
//!   - static styles use `ui.css(...)`, state styles use `ui.cva(...)`: tokens via unified
//!     `TOKENS`, resolved at compile time by field category, typos are errors; don't write
//!     color / font literals.
//!   - token values are fetched on apply, so theme switches auto-replay and styles follow.
//!   - styles needing logic (branch on `t.scheme` etc) still write `fn (*const
//!     ui.theme.Values) BoxStyle`; both patterns can mix.
const ui = @import("ui");
const TOKENS = ui.theme.refs;

pub const root = ui.css(.{
    .width = .fill,
    .height = .fill,
    .direction = .column,
    .gap = TOKENS.space.space300,
    .padding = TOKENS.space.space1000,
    .background = TOKENS.color.bg_primary,
    .align_items = .center,
    .justify = .center,
});

pub const title = ui.css(.{ .typography = TOKENS.typography.counterTitle });

// App's own counterValue token, keeps original 18px.
pub const counterText = ui.css(.{ .font_size = TOKENS.font_size.counterValue });

pub const derivedText = ui.css(.{ .color = TOKENS.color.fg_secondary });

pub const buttonRow = ui.css(.{ .gap = TOKENS.space.space200 });

/// Even/odd badge: business layer provides even, recipe manages override and hover.
pub const Badge = ui.cva(.{
    .base = .{
        .padding = .{ .x = TOKENS.space.space300, .y = TOKENS.space.space100 },
        .corner_radius = TOKENS.radius.full,
        .background = TOKENS.color.bg_secondary,
        .border = .{ .width = TOKENS.border_width.thin, .color = TOKENS.color.border },
        ._hover = .{ .opacity = 0.8 },
    },
    .variants = .{ .even = .{
        .false = .{},
        .true = .{ .background = TOKENS.color.success_subtle, .border_color = TOKENS.color.success },
    } },
    .defaults = .{ .even = false },
});

pub const badgeText = ui.css(.{ .font_size = TOKENS.font_size.sm, .font_weight = TOKENS.font_weight.semibold });
