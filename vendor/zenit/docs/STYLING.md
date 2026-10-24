# Decoupling Styling from Business Logic: the zenit Styling Layering Guide

> Current API: [Design System Tokens](DESIGN_SYSTEM_TOKENS.md) and
> [build integration](design-system/TOOLING.md). Examples use `examples/theme.json`
> and `const TOKENS = ui.theme.refs`. Application values are `t.tokens.*`;
> builtin recipes read the same `t.tokens.*` semantic materials. Component size variants belong to recipes.

zenit has no separate styling file format (CSS/DSL). Style objects are plain
Zig data structures (`BoxStyle` / `TextStyle` / `ConditionalStyle`); the
decoupling is achieved through a three-layer convention that mirrors the
division of labor between design tokens / CSS Modules / CVA (Panda CSS) in
the web ecosystem.

## The three-layer model

### Layer 1: tokens are the only bridge between styles and code

Shared colors, font sizes, spacing and radii come from the generated
`ThemeTokens` (`src/ui/theme.zig`): `t.tokens.color.*`, `t.tokens.space.*`,
`t.tokens.font_size.*`, `t.tokens.radius.*`, or typed `ui.theme.refs` in css objects.
Base scales belong in `tokens`; semantic roles and typography aggregation belong
in `semantic`. Both share one reference namespace. Spacing uses `space50` (2),
`space100` (4), `space200` (8), etc.

**Convention: bare color and font-size literals are forbidden in view-building
code** (`Color.hex(...)`, `.font_size = 24`). Literals bypass the token
scale, so themes cannot swap them and global changes cannot reach them.
`scripts/check_style_literals.sh` enforces a ratchet over examples/ that only
lets the count go down, never up.

**Escape hatch (arbitrary values)**: tokens cannot possibly cover every
design: matching a specific mockup, one-off brand colors, and pixel-level
nudges are all legitimate needs (cf. Panda's `[18px]` / `[#316ff6]`). In
those cases mark the value explicitly with `ui.arb.*` instead of writing a
bare literal:

```zig
.font_size = ui.arb.px(18),          // intentionally off-scale
.background = ui.arb.hex(0x316FF6),  // one-off brand color
.border_color = ui.arb.hexA(0x000000, 0.12),
```

`ui.arb` is an inline identity wrapper with zero runtime cost; the difference
is entirely semantic and toolchain-facing: readers can tell at a glance an
"intentional arbitrary value" apart from a "lazy literal that should have
migrated to a token"; the ratchet only catches bare literals and lets `arb`
through by construction; a global grep for `ui.arb` inventories every
off-token value. Once the same value shows up more than three times,
consider promoting it to a token.

ControlShell's size matrix lives in its `styles.zig` `sva` recipe. The theme
provides reusable font, spacing, radius and icon materials; the component owns
how they combine. `ui.widgets.ControlSize` selects a variant, and
`ui.widgets.control_shell.metrics(t, size)` exposes resolved measurements to
controls sharing the shell layout. There is no theme `control` category or
fixed-default measurement method on size enums. Badge and Tag size choices
likewise live in their recipes.

### Layer 2: named style functions (styles.zig): the Zig equivalent of CSS Modules

> Components whose view is written in Yix keep their styles in `styles.yss` instead (declarative recipes /
> styles in YSS, functions with parameters kept as plain Zig in the same file; see docs/YSS.md). `.yix` files
> import `styles.yss` (the compiler rewrites it to the checked-in twin `_styles.yss.zig`); hand-written Zig imports
> the twin directly. The rules below still apply to components that are written in Zig.

Each feature/example gets one `styles.zig` that exports pure functions:

```zig
// styles.zig
const ui = @import("ui");

pub fn card(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .background = t.tokens.color.bg_secondary, .padding = ui.Padding.all(t.tokens.space.space400) };
}
pub fn title(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.tokens.font_size.xxl, .font_weight = 600, .color = t.tokens.color.fg_primary };
}
```

View code consumes them through the `.style` prop of `ui.view` elements
(see [`VIEW_DSL.md`](VIEW_DSL.md)):

```zig
const S = @import("styles.zig");
const v = ui.view;

v.col(.{ .style = S.card }, .{
    v.text(.{ .style = S.title }, "Hello"),
})
```

Styles are named, reusable, and unit-testable; grepping a name finds every
usage site. `.style` also composes and reacts:

| `.style =` | Meaning |
|---|---|
| `S.card` | one named style function |
| `.{ S.card, S.compact, .{ .gap = 4 } }` | merged left to right (later wins) |
| `S.Card.of(.{ .selected = selected })` | a cva variant follows a bool source |
| `v.hover(S.cardHover)` | layered while the node is hovered |
| `S.sized.of(.{ .width = w })` | a parameterized style (`.yss` `style sized($width: ?f32) { … }`, see YSS.md); each argument may be a source |
| `v.styleBy(size, S.sized)` | `fn (T, tokens) BoxStyle` picked by a source value (text: returns `TextStyle`) | — escape hatch for styles only Zig can compute |

#### Object styles and slot recipes

Token-only named styles can use `ui.css` instead of a function. Token names
are checked at compile time and resolved against the current theme:

```zig
pub const card = ui.css(.{
    .background = .bg_secondary,
    .padding = .space400,
    .corner_radius = .md,
    ._hover = .{ .background = .bg_hover },
});
```

`ui.cva` adds shared variant dimensions to one style. `ui.sva` applies the
same dimensions to multiple named slots:

```zig
const Tile = ui.sva(.{
    .slots = .{ .root, .label },
    .base = .{
        .root = .{ .padding = .space200, ._hover = .{ .background = .bg_hover } },
        .label = .{ .color = .fg_secondary },
    },
    .variants = .{ .selected = .{
        .false = .{},
        .true = .{ .label = .{ .color = .accent } },
    } },
    .defaults = .{ .selected = false },
});
const parts = Tile.of(.{ .selected = selected_signal });
v.box(.{ .style = parts.root }, v.text(.{ .style = parts.label }, "Tile"))
```

`Tile.resolve(variants, tokens)` returns one `ConditionalStyle` per slot for
box-only recipes. Mixed box/text recipes use `Tile.of(args)` in the view;
component authors can call `Tile.Slot(.root).resolve(vs, tokens)` or
`Tile.Slot(.label).resolveText(vs, base_text, tokens)` for an individual target.
A projected slot never resolves its siblings, so a text-only property such as
`max_lines` on a label does not need to be valid on the root box. `Tile.of(args).root` and `Tile.slot(.root, args)` produce
view style parts; sources, hover, and theme replay use the existing cva path.
For widgets exposing named parts, use their normal wrapper, for example
ScrollArea's `.parts = .{ .content = .{ .style = parts.root } }`.

The sva merge order is **base < variants < derived < compound**. Every option
and compound style is a map from declared slot names to css objects or
literals. Omitted slots stay empty. An optional `derived(variants, tokens)`
function returns a record of `BoxStyle` values (it may contain a subset of
slots); it supplies base geometry, without condition layers. Omit text slots
from `derived`; projecting a slot absent from its return type skips that function.
Keep colors in
base/variants/compound, following the existing recipe convention.
Variant defaults use `.defaults`, otherwise the first option; `.true` /
`.false` option names produce a bool dimension. `Dim(.name)` exposes its type.

**Theme-safe**: a style that is known at compile time (functions, constant
literals and tuples of them) attaches an `on_theme` hook to the node. The
full-tree walk performed by `Cx.setTheme` replays the style with the new
tokens (including background/opacity via paint_state, and marks layout dirty).
Styles with `when` / `hover` / `styleBy` parts run one effect that follows both
the conditions and the theme signal; when a condition is withdrawn, the fields
it set go back to their base values instead of sticking. Writing token values
into a literal (`.{ .background = cx.tokens.tokens.color.X }`) takes a snapshot at
mount time that does not follow the theme, which is why styles live in
functions of the tokens.

`on_theme` is not a before_render hook: it does not run every frame and does
not affect eligibility for the promoted render cache (the
`promoted_cache_safe` predicate is unaware of it), so it is safe to use on
large containers. Limitation: `setTheme` only walks the `cx.root` subtree;
nodes in separate overlay trees are not covered.

### Layer 3: recipes: styles with variants/interaction states (the CVA / Panda equivalent)

`ui.recipe` (`src/ui/recipe.zig`) is public API; applications can define
their own recipes:

- `ui.ConditionalStyle`: a style bundle that declares base plus seven
  condition states in one place
  (selected/expanded/hover/active/focus/invalid/disabled, see the
  "Condition system" section below);
- `ui.recipe.recipe(Config)`: single-node recipe; resolve order is
  **base < variants < derived < compounds** (external style overrides come
  last);
- `ui.recipe.slotRecipe(Config)`: multi-part recipe (cf. Panda sva);
- `ui.transition("background 200ms ease-out")`: a transition declaration
  parsed at comptime.

`derived(variants, tokens)` receives the full Variants and carries
cross-dimensional composition logic (e.g. padding = f(size, icon mode)), a
"continuous function-style composition" that neither a single-dimension
resolver nor the enum-AND-matched compounds can express. Prefer `derived` for continuous geometry. This is authoring guidance, not a compiler-enforced field whitelist. `bgColors()` reads the final merged ConditionalStyle, including derived; background changes there are not inherently invalid. Keep finite visual choices in variants/compound for clarity.

Freeze recipe variants into theme-safe style functions (a function taking a
comptime parameter and returning a function):

```zig
pub fn panel(comptime emphasis: PanelEmphasis) fn (*const ui.ThemeTokens) ui.BoxStyle {
    return struct {
        fn f(t: *const ui.ThemeTokens) ui.BoxStyle {
            return PanelRecipe.resolveBase(.{ .emphasis = emphasis }, t);
        }
    }.f;
}
// usage: v.box(.{ .style = S.panel(.highlight) }, .{ ... })
```

A variant chosen at runtime goes through `v.styleBy`:

```zig
pub fn panelFor(emphasis: PanelEmphasis, t: *const ui.ThemeTokens) ui.BoxStyle {
    return PanelRecipe.resolveBase(.{ .emphasis = emphasis }, t);
}
// usage: v.box(.{ .style = v.styleBy(emphasis_signal, S.panelFor) }, .{ ... })
```

### Object syntax: `ui.css` / `ui.cva` (the Panda `css()` / `cva()` equivalent)

Layers 2 and 3 can also be written as objects, with no function body
(`src/ui/css.zig`). Everything is resolved at comptime; nothing is parsed at
run time:

```zig
pub const card = ui.css(.{
    .background = .bg_secondary,          // color field  -> tokens.color.*
    .padding = .{ .x = .space400, .y = .space200 },   // space fields -> tokens.space.*
    .corner_radius = .md,                 // -> tokens.radius.*
    .width = ui.arb.px(240),              // a number is an arbitrary value
    .height = .fill,                      // sizes: number (px), .fill, .fit, .{ .percent = n }
    ._hover = .{ .background = .bg_hover },
});

pub const Btn = ui.cva(.{
    .base = .{ .corner_radius = .md, .padding = .{ .x = .space300 } },
    .variants = .{
        .intent = .{ .primary = .{ .background = .accent }, .ghost = .{ ._hover = .{ .background = .bg_hover } } },
        .size = .{ .sm = .{ .gap = .space100 }, .md = .{ .gap = .space200 } },
        .block = .{ .true = .{ .width = .fill }, .false = .{} },   // true/false options make a bool variant
    },
    .compound = .{ .{ .when = .{ .intent = .ghost, .size = .sm }, .style = .{ .padding = .{ .x = .space100 } } } },
    .defaults = .{ .size = .md },                                   // a variant without a default uses its first option
});

v.col(.{ .style = card }, .{ ... })
v.box(.{ .style = Btn.of(.{ .intent = intent_signal }) }, .{ ... })   // variant values may be signals
```

- **Field names are the `BoxStyle` / `TextStyle` field names.** `color` and
  `text_color` are aliases (text color on a box, `color` on a text node).
  Declare only one spelling per layer; duplicate aliases are a compile error.
- **Tokens are referenced by name and checked by field category**: color
  fields (`background`, `color`, `*_color`) look in `tokens.color`; `gap`,
  `padding`, `margin` in `tokens.space`; `corner_radius` in `tokens.radius`;
  `font_size` in `tokens.font_size`; `border_width` / `border_*_width` in
  `tokens.border_width`; `shadow` in `tokens.shadow`. Inside `.border` the
  `color` / `width` / `radius` fields follow the same rule. An unknown name is
  a compile error that lists the names available in that category, and
  renaming a token breaks every use. Transparent literals use `ui.Color.TRANSPARENT`;
  `.transparent` only works when the application declares that color token; `font_weight` takes `.regular`, `.medium`, `.semibold`, `.bold`, etc.
- **Theme-safe by construction**: tokens are read when the style is applied,
  so a style object (and an inline literal that references tokens, such as
  `.style = .{ .gap = .space200 }`) replays on `setTheme` like a style function
  does. This removes the "a literal snapshots the theme" pitfall described
  above.
- **Conditions** are `_selected _expanded _hover _active _focus _invalid
  _disabled`, the condition system below with Panda's naming; precedence is
  fixed by that system, not by the order they are written in. On a plain box
  only `_hover` has a state source; any other condition there is a compile
  error pointing at cva / sva variants for data-driven states. Components get the full
  `ConditionalStyle` through `@TypeOf(card).conditional(t)` /
  `Btn.resolve(variants, t)` and apply it with their own state.
- **cva** merges `base < variants < compound`, the same order as
  the function recipe without its optional derived stage. cva accepts only base/variants/compound/defaults; sva and function recipes also support derived.
  `Btn.Variants` is the generated variants struct and `Btn.Dim(.size)` one
  dimension's type, so component props can be declared with it; a value from
  another enum with matching option names is converted by name.
- **Text styles layer**: a text node starts from the theme's default text
  style; a `TextStyle` value or a style function replaces it, while a style
  object or literal changes only the fields it declares. Text therefore also
  accepts cva recipes and individual sva slots, including reactive variants.
  Each update starts from the current defaults and declared base, so properties
  belonging only to the previous variant are removed. Conditions on a text slot
  are compile errors; map the desired state to a variant instead.
- **Override order** is only ever what you can see: the component's own
  recipe, then the caller's `.style` / `.parts`, then left to right inside one
  `.style` tuple.

### Condition system (the curated subset of Panda conditions)

The condition flags of `ConditionalStyle` are the subset of Panda's built-in
conditions for which the component library has real consumers:

| Condition flag field | InteractionState bit | Panda equivalent | Semantics |
|---|---|---|---|
| `selected` | `is_selected` | `_checked`/`_selected` | Persistent selected/checked state (the two merged into one: they never coexist on the same node) |
| `expanded` | `is_expanded` | `_expanded` | Expanded state (accordion/tree/chevron) |
| `hover`/`active`/`focus` | `is_hovered`/`is_pressed`/`is_focused` | `_hover`/`_active`/`_focus` | Interaction states |
| `invalid` | `is_invalid` | `_invalid` | Validation failure |
| `disabled` | `is_disabled` | `_disabled` | Disabled (short-circuits; mutually exclusive with all the others) |

The resolve precedence chain is
**base ← selected ← expanded ← hover ← active ← focus ← invalid**, with
disabled short-circuiting everything. Reasons for this order:
- selected/expanded are persistent base states that interaction states layer
  on top of (a selected row can still be hover-highlighted);
- focus coming after active is an existing, deliberate design: zenit's focus
  visuals primarily go through `useFocusRing` (a separate ring layer), and
  `ConditionalStyle.focus` is the fallback channel for scenes without a
  ring; placing it later guarantees the fields it sets are not eaten by the
  interaction states;
- invalid overrides all interaction states: an error border must win over
  hover/focus (aligning with Input semantics).

**Light/dark theme is not a condition.** Theme differences are handled first
by swapping the token layer wholesale (light/dark are two complete sets of
token values, so style functions naturally receive the correct value); when
an individual style genuinely needs to branch on light/dark and it is not
worth minting a token, use the `t.scheme` escape hatch
(`ThemeTokens.ColorScheme`):

```zig
.shadow = if (t.scheme == .dark) heavy_shadow else soft_shadow,
```

No dark condition is added to ConditionalStyle, since two sources of dark values
would fight each other. By the same reasoning there is no group/peer hover
(needs event-system support, tracked separately) and no pseudo-elements/media
queries (no CSS-engine counterpart).

## Runtime contract for object styles

`ui.css`, `ui.cva`, and `ui.sva` require comptime declarations. Property names,
slot projection, option names, token categories and condition structure are
checked at compile time. A shared resolver emits writes for declared properties;
static recipe layers do not construct and merge complete intermediate styles.
This is **zero runtime declaration parsing**, not zero UI work: variant tests,
typed token reads, conditional application, node diffs and layout/render updates
still happen when their inputs change. No variant Cartesian-product table or
runtime style-object allocation is required by this resolver.

Use cva for one element and sva when variants coordinate several named elements.
Map business state to variants with ordinary Zig functions and `ui.map` / `map2`.
Partial overrides go over `base`; complete alternatives can use an empty base.
Unspecified fields in a layer preserve previous layers, while switching variants
rebuilds the result and removes fields owned only by the previous choice. An
omitted slot adds no override. Multiple variant dimensions apply in declaration
order; matching compounds apply in list order. Null box fields add no override.

Padding and margin are whole-property replacements between layers; inside one
value, explicit edges override `x` / `y` regardless of field order. Border and
its fine-grained overrides retain `BoxStyle` semantics. Text expands typography
before explicit properties in each layer, then applies subsequent layers.

All runtime box styles on one node form a single cascade (low → high): the element's own
`style=`, the component's inline writes (`setBackground` / `setOpacity` / `setBorderColor` /
`setTranslateX` / `node.setStyleInline`, undone with `node.unsetStyleInline`), the caller's
overlay (`v.attrs(.{ .style })`, `.parts.*.style`), and animations (`ui.view.loop`). A caller
overlay always wins over the component's own styles; when a layer stops declaring a property
it falls back to the next layer, then to the default. Layers are stored as sparse declarations
(`ui.StyleDecl`), and only the properties that changed between two cascade results are applied.
A layer's first application and animation-driven values apply immediately; other changes go
through declared transitions starting from the currently presented value.

`derived` and `view.styleBy` execute application functions at runtime. They are
explicit dynamic paths for computed geometry/values, outside the static object
promise. Text slots reject layout properties and interaction conditions, even
when the offending variant is initially inactive. `view.when` remains a supported low-level conditional override; finite business states should use recipe variants. Static tuples are expanded at comptime; reactive conditions subscribe at runtime.

## Reference examples

- `examples/counter_reactive/`: `S.Badge.of(.{ .even = even })` binds a
  business-state source to a cva recipe, with hover declared in its base.
  The matching Yix counter uses the same recipe.
- `examples/hello_button/`: `S.Panel.of(...)` maps the counter to an application
  emphasis variant.
- Inside the framework: `ControlShellRecipe`
  (`src/ui/components/control_shell/`) is the most complete derived use case
  (variant × size × pill × icon_only × leading_icon).

## `styles.zig` test collection

Every component that has its own `styles.zig` ends its `mod.zig` with:

```zig
// styles.zig 的测试收集 — 见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}
```

This line is load-bearing. `const styles = @import("styles.zig")` at the top
of `mod.zig` does **not** cause the tests inside `styles.zig` to be collected:
`refAllDecls` only recurses into `pub` decls that are actually referenced, and
the import binding is not `pub`. Without the explicit `_ = @import(...)`,
tests added to `styles.zig` later are silently never run: the file compiles,
the suite is green, and the assertions never execute.

The repo has a gate for exactly this failure mode:
`bash scripts/check_orphan_tests.sh` plants a runtime failure in each test
file and verifies the suite actually goes red.
