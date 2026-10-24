# Migration notes

zenit is pre-1.0 and breaking changes happen. This file lists them in
reverse chronological order so consumers can see what to fix when bumping.

> Which APIs are frozen for v1.0 vs. still fair game: see
> [`docs/API_STABILITY.md`](API_STABILITY.md).

## How to add an entry

When you land a breaking change, prepend a section here with:

- the date and a one-line summary ending in `(BREAKING)`
- **what changed**: the old shape and the new shape
- **why**: enough that a consumer can tell whether it affects them
- a mechanical migration snippet (before / after code), not prose

`CONTRIBUTING.md` makes this part of the PR checklist for any change that
alters a public symbol.

---

## 2026-10-15: macOS non-precise wheel deltas are pixels (BREAKING)

**What changed.** `ScrollEvent.dx/dy` from a non-precise wheel (ratchet mouse)
were raw AppKit line units (typically ~0.1 per detent, up to ~15 on fast flicks).
They are now logical points, converted at the event bridge (`40 px/line`).
Precise devices (trackpads, Magic Mouse) already reported points and are
unchanged.

**Why.** Line units reached `scroll_area`, which applies `dx/dy` as pixels
(`scroll_speed` multiplies them): one detent scrolled ~0.1 px and fast flicks
drifted unpredictably. 40 px/line is the shared constant of Chromium
`kScrollbarPixelsPerCocoaTick`, WebKit `Scrollbar::pixelsPerLineStep` and
Flutter `pixelsPerLine`.

**Migration.** Drop any line-unit compensation you added for `ScrollEvent.dx/dy`:

```zig
// before
const px = ev.dy * 40; // or scroll_speed = 40, * line_height, ...
// after
const px = ev.dy; // already logical px
```

## 2026-10-12: renderers initialize in place (BREAKING)

**What changed**: `AppRenderer.init` and `ImageRenderer.init` now take a
`self` pointer and return `!void`. Nested `IconRenderer.init` follows the same
convention; `ImageTextureStore.init` takes a `self` pointer and returns `void`.

**Why**: returning renderers and texture stores by value produced multi-megabyte
Debug stack frames and could overflow the macOS main-thread stack when opening
another window. Initialization now writes directly into caller-owned storage and
rolls back acquired GPU resources on failure. Call `deinit` only after successful
initialization, and destroy the storage separately.

**Migration**

```zig
// before
renderer.* = try AppRenderer.init(allocator, io, device, queue, surface, config);
var image = try ImageRenderer.init(allocator, device);
defer image.deinit();

// after (renderer is already allocated)
try renderer.init(allocator, io, device, queue, surface, config);
const image = try allocator.create(ImageRenderer);
defer allocator.destroy(image);
try image.init(allocator, device);
defer image.deinit();

// Likewise for IconRenderer and ImageTextureStore:
try icon.init(allocator, device);
store.init(allocator, device, true); // shared namespace; no fallible allocation
```

## 2026-10-12: `ResourcePath.init` takes an `std.Io` (BREAKING)

**What changed**: `zenit_app.ResourcePath.init()` became `init(io: std.Io)`.
Zig 0.17 removed `std.fs.selfExePath` and the Io-less directory API, so the
executable path and the `assets/` probe now go through the caller's `Io`. The
probe uses native path separators, so an `assets/` directory beside a Windows
`.exe` is found too.

**Why**: the previous body no longer compiled under Zig 0.17; it was only
analysed by applications that call it.

**Migration**

```zig
// before
const res = ResourcePath.init();
// after
const res = ResourcePath.init(io); // e.g. init.io from main(init: std.process.Init)
```

## 2026-10-03: `ui.view` is the way to build UI; control flow is anchored (BREAKING for child-index code)

**What changed**

1. `ui.view` (declarative element tree) and `ui.on` (event combinators) are the
   app-facing way to build UI. All examples, the template and the docs use them.
   The node builders (`ui.box`, `ui.text`, `boxStyled`, …) remain for code
   inside components.
2. `Show` / `Match` / `For` now keep their content at the position where they
   were called. Each region owns a pair of `ElementTag.anchor` nodes
   (`display: none`: no size, no gap, skipped by hit testing and a11y) in the
   parent. Code that counts or indexes `parent.children` directly now sees the
   anchors.
3. `BoxStyle.merge` / `isEmpty` cover every field (they used to drop `display`).

**Why**: previously, Show / Match appended content at the end of the parent when
the condition turned true later, and For positioned itself by counting earlier
siblings, so mixing control flow with other children reordered the UI.

**Migration**

```zig
// before
const root = try ui.box(cx, .{ .gap = 8 }, .{});
try root.appendChild(cx.allocator, try ui.text(cx, "Title", .{}));
const counter = try cx.bindState(Counter, .{ .count = count });
try root.appendChild(cx.allocator, try W.Button(.{
    .label = "+1",
    .on_click = cx.on(Counter, counter, Counter.increment),
}).mount(scope, cx));
try root.appendChild(cx.allocator, try ui.textFmt(cx, scope, "{d}", .{count}, .{}));
return root;

// after
return v.render(scope, cx, v.col(.{ .style = S.root }, .{
    v.text(.{ .style = S.title }, "Title"),
    W.Button(.{ .label = "+1", .on_click = ui.on.update(count, inc) }),
    v.text(.{}, v.fmt("{d}", .{count})),
}));
```

| Before | After |
|---|---|
| `ui.box / hstack / vstack(cx, style, .{})` + `appendChild` | `v.box / v.row / v.col(.{ .style = … }, .{ children })` |
| `ui.boxStyled(cx, S.card, …)` / `textStyled` | `.style = S.card` |
| `ui.textFmt(cx, scope, fmt, args, style)` | `v.text(.{ .style = … }, v.fmt(fmt, args))` |
| `Bindings` struct + `cx.bindState` + `cx.on` for one click | `ui.on.set / toggle / update / assign`; shared state: `ui.on.call(ptr, T.method)` |
| `Widget(props).mount(scope, cx)` + `appendChild(result.container)` | `Widget(props)` as a child; `v.with(Widget(props), .{ children })` for slots |
| `node.meta.ownership.meta.test_id = …` after mount | `v.attrs(.{ .test_id = … }, Widget(…))` (boxes and text take `.test_id` directly) |
| `ui.Show(scope, parent, cond, cx, struct { fn build … })` | `v.show(cond, .{ … }).fallback(.{ … })` |
| `ui.Match(T, …)` / `ui.For(T, …)` | `v.match(value, .{ .tag = … })` / `v.each(items, .id, row)` |
| `inline for (specs) |s| appendChild(…)` | `v.list(&specs, f)` |
| `VirtualList(…).mount(scope, cx, render)` | `VirtualList(…).rows(ctx, row)` |
| Node fields set by hand (raw events, hooks) | `v.setup(element, ctx, f)` |

Code that indexes `parent.children` of a container holding `Show` / `Match` /
`For` should skip `node.tag == .anchor`.

## 2026-10-03: Text fields keep the caret when `ui.split` rewrites or rejects an edit

No API change. Input, Textarea and EditableText bound with `ui.split` used to
treat a rewritten or rejected user edit like an outside write: the whole text
was replaced, the caret jumped to the end, the selection was lost and the undo
history was cleared. With an upper-casing, digits-only or max-length parent,
typing in the middle of the text moved the caret to the end after every key and
Cmd+Z stopped working.

Now the field corrects itself in place:

- **Rejected** (the value did not change): the text, caret and selection are
  restored to what they were before the edit, and the undo and redo history
  is exactly as it was (the edit leaves no undo step and does not clear redo).
  A rejected undo / redo is reverted too.
- **Rewritten**: the text becomes the landed value and the caret stays at the
  edit point (for example after the inserted, upper-cased character). The
  rewrite is part of the same undo step, so Cmd+Z returns to the text before
  the edit.

`on_change` is still called only with the landed value, and by the time it runs
the field already shows that value. Writes from outside (the parent setting the
signal on its own) keep their behavior: the text is replaced, the caret moves to
the end, the undo history is cleared and `on_change` is not called.

Nothing to migrate. If you worked around the old behavior (for example by
moving the caret back yourself after the write), remove the workaround.

## 2026-10-02: Select `placeholder` accepts a signal; Steps updates the current step in place

**Select.** `placeholder` is a `Source([]const u8)`. String literals keep
working; pass a signal or derived value to change the hint at runtime (i18n,
"Loading…", a hint that depends on another field). The trigger shows the
current hint while nothing is selected; a searchable single Select uses it as
the search placeholder.

**Steps.** No API change. A change to `current` now restyles the existing steps
(circle, check icon, title, connector, a11y state) instead of rebuilding them;
only an `items` change rebuilds. Fixed: with `current` at or past the last
step, the horizontal progress line now ends at the last circle instead of
running past it.

## 2026-10-02: DropdownMenu is merged into Menu (BREAKING)

**What changed.** The two components had identical item visuals, keyboard
navigation and open pipeline; they differed only in how a choice was reported.
`ui.widgets.DropdownMenu` / `DropdownItem` / `DropdownItemKind` /
`DropdownMenuState` are removed, and `Menu` now does both:

| Before | After |
|---|---|
| `W.DropdownMenu(.{ .items = &items })` | `W.Menu(.{ .items = &items })` |
| `DropdownItem` / `DropdownItemKind` | `MenuItem` / `MenuItemKind` (same fields: `icon_asset`, `on_click`, `shortcut`, `danger`, `disabled`) |
| `DropdownMenuState` | `MenuState` |
| `DropdownMenuItemRecipe` | `MenuItemRecipe` |
| `Menu` `items: []const MenuItem` read once | `items: Source([]const MenuItem)`: pass a signal or derived value to rebuild the items when a new array is set |
| `ui.widgets.menu_navigation` | removed (its only remaining user is Menu) |

Per-item `on_click` and the menu-wide `on_select(id)` can be used together;
choosing an item requests closing first, then calls `on_select`, then the
item's `on_click`. Menu also gains DropdownMenu's `max_height` (the panel
scrolls past it) and icons.

**Item lifetime.** A static array is copied at mount together with its
strings (a function-local array is fine). Items from a signal are borrowed:
the array and its strings must stay valid until the signal holds a different
value.

**Visual change.** Menu separators now use DropdownMenu's layout: a 1px line
with 4px space above and below. Before, Menu drew a 1px line with no extra
space.

## 2026-10-02: Card / GlassBox titles and FormField labels accept signals (BREAKING)

**What changed.** `Card` and `GlassBox` take `title` / `subtitle` as
`Source([]const u8)` (`""` = none; was `?[]const u8`). `FormFieldOf(T).field`
/ `inputField` take the field config as an anytype literal, and its
`label_text` / `helper` are `Source([]const u8)`. A signal updates the text
after mount; an empty value hides the row. New `ui.bindOptionalTextRow` is the
shared primitive.

**Migration.** `.title = null` becomes `.title = ""` (or leave it out).

---

## 2026-10-02: DatePicker and DateRangePicker take `open: Model(bool)` and a dynamic `disabled` (BREAKING)

**What changed.** Both pickers gain `open: Model(bool)` + `on_open_change`
(the result gains `open: ?*Signal(bool)`), and `disabled` is a
`Source(bool)`. Opening the panel by any route (click, outside write to
`open`) resets the calendar to the selected month. `PopoverResult` gains
`show` / `toggle` handlers (same proposal pipeline as `close`) and
`open_read: Source(bool)` for components that wire their own trigger.

**Why.** Every overlay exposes its open state the same way; a form can
disable a picker while it is submitting.

**Migration.** Code that read the panel state through `stateOf(result).is_open`
uses `result.open` (or pass a signal as `.open`).

---

## 2026-10-02: Text components (Input, Textarea, EditableText, TagsInput, ComboBox) take Models (BREAKING)

**What changed.**

| Before | After |
|---|---|
| `initial_value: ?[]const u8` (read once), `result.state.setText(...)` to write later | `value: Model([]const u8)`: a literal is the initial text; a `*Signal([]const u8)` from `scope.createText` is the value source edits write to; `ui.split` lets the parent accept, transform or reject each edit |
| `on_change: ?HandlerRef` (`Cx.strHandlerFrom`) | `on_change: ?Handler([]const u8)` (`cx.on(S, s, S.changed)`), called with the landed value |
| — | `on_submit: ?Handler([]const u8)`: Enter in a single-line input |
| `state_id` (never read), builder setters `.placeholder() .label() .helper() .errorMsg() .required() .disabled() .width()` | removed; pass the fields in the literal |
| `Input(props: InputProps)` | `Input(props: anytype)` like every other component; `InputResult` gains `value: ?*Signal([]const u8)` |
| `label_text` / `helper` / `error_msg` / `placeholder: ?[]const u8`, `disabled: bool` | `Source([]const u8)` (`""` = none) and `Source(bool)`: a signal updates the label, helper, error state (border, colours, `invalid`), placeholder and disabled state after mount |
| `FormFieldOf(T).inputField(field, config, props: InputProps, …)` | `props` is an anytype literal like `W.Input(.{...})` |
| EditableText: `value: ?[]const u8` (read once), `on_change: ?HandlerRef` | same rules as Input; `result.setText(text)` (switching the edited object) now writes the value signal and applies at once, even mid-composition; `EditableTextResult` gains `value` |
| TagsInput: `W.TagsInput(props, scope, cx)`, `initial_tags` (each fired `on_change`), `on_change: ?HandlerRef` (no payload), tags held in `state` (`addTag` / `removeSlot`) | `W.TagsInput(props).mount(scope, cx)`; `tags: Model([]const []const u8)` (a bound signal must come from `scope.createList([]const u8, …)`), `on_change: ?Handler([]const []const u8)`, `placeholder` Source; result `{ wrapper, input, tags, state }` |
| ComboBox: `W.ComboBox(props, scope, cx)`, `on_change: ?HandlerRef` (read `state.selectedOption()`), `is_open` signal, static `options` / `label_text` / `disabled` | `W.ComboBox(props).mount(scope, cx)`; `value: Model(?[]const u8)` (committed option value) + `on_change: ?Handler(?[]const u8)`, `open: Model(bool)` + `on_open_change`, `options` / `label_text` / `placeholder` / `disabled` Sources; typing clears the committed value; result `{ wrapper, input, panel, value, open, state }` |
| Textarea: `value: ?[]const u8` (read once), `on_change: ?HandlerRef`, `context` (never read), builder setters, `mountWithState` returning `TextareaMount` | same rules as Input: `value: Model([]const u8)`, `on_change: ?Handler([]const u8)`, `label_text` / `helper` / `error_msg` / `placeholder` / `disabled` accept signals; `mountResult` returns `TextareaResult { wrapper, input, state, value }` |

Writes to the value from outside (the parent setting the signal) replace the
text, move the caret to the end and clear the undo history; they do not call
`on_change`. While the user is composing with an input method, outside writes
wait: if the composition is committed the user's text wins, if it is
cancelled the latest outside value is applied.

**Why.** One text-ownership and binding rule for every text field (§4.8);
programmatic writes no longer go around the component.

**Migration.**

```zig
// before
const r = try W.Input(.{ .initial_value = "draft", .on_change = ui.Cx.strHandlerFrom(S, s, S.changed) }).mountResult(scope, cx);
_ = r.state.setText("reset");
// after
const text = try scope.createText("draft", .{});
const r = try W.Input(.{ .value = text, .on_change = cx.on(S, s, S.changed) }).mountResult(scope, cx);
text.set("reset");
```

---

## 2026-10-02: Form fields are owned signals; `on_submit` is a Handler (BREAKING)

**What changed.**

| API | Before | After |
|---|---|---|
| `FormOf(T).create` config | `on_submit: ?*const fn (T, *anyopaque) void` + `submit_context` | `on_submit: ?Handler(T)` (`cx.on(S, s, S.submit)`) |
| `FormOf(T).setValueCopy` | copy variant for text fields fed from a temporary buffer | removed: text fields are owned text signals, `setValue` copies |
| Field signals | not reachable | `form.field(.email)` / `store.field(.email)` returns the field's `*Signal`, ready to bind into a component |
| Submit button | wire `handleSubmit` by hand | `.on_click = form.submitHandler()` |
| `Form(props)` layout container | typed `FormProps` | anytype literal like every other component |

`StoreOf(T)` creates `[]const u8` fields with `scope.createText`; a value read
from such a field is valid only during the current call (copy it to keep it).

**Why.** One text-ownership rule for the whole framework (§4.8) instead of a
Form-only copy helper; typed submit handler.

**Migration.**

```zig
// before
const form = try W.FormOf(Login).create(scope, init, .{ .on_submit = S.submit, .submit_context = s });
form.setValueCopy(.email, text) catch {};
// after
const form = try W.FormOf(Login).create(scope, init, .{ .on_submit = cx.on(S, s, S.submit) });
form.setValue(.email, text);
const submit = try W.Button(.{ .label = "Sign in", .on_click = form.submitHandler() }).mount(scope, cx);
```

---

## 2026-10-02: VirtualList takes a row-count Source; ScrollArea and Grid use the common entry point (BREAKING)

**What changed.**

| Component | Before | After |
|---|---|---|
| VirtualList | `item_count: usize` (call `updateItemCount` by hand when it changes), builder setters `.width() .height() .overscan() .padding() .background()`, `state.props.item_count` | `item_count: Source(usize)` and `data_version: Source(u64)` (rows redraw when either changes); setters removed, pass the fields in the literal; the applied count is `state.item_count`. `updateItemCount` still works for callers that drive the count themselves |
| ScrollArea | `W.mountScrollArea(props, scope, cx)` | `W.ScrollArea(props).mount(scope, cx)` (same props and result) |
| Grid | `W.mountGrid(props, scope, cx)` | `W.Grid(props).mount(scope, cx)` (same props and result) |

**Why.** One way to create every component; a list whose length lives in a
signal no longer needs an effect in the caller to keep the list in sync.

**Migration.**

```zig
// before
const vl = try W.VirtualList(.{ .item_count = rows.items.len, .item_height = 28 }).width(320).mount(scope, cx, render);
// ... after every change: ui.widgets.virtual_list.updateItemCount(vl.state, rows.items.len);
const sa = try W.mountScrollArea(.{ .height = 240 }, scope, cx);

// after
const vl = try W.VirtualList(.{ .item_count = row_count, .item_height = 28, .width = 320 }).mount(scope, cx, render);
const sa = try W.ScrollArea(.{ .height = 240 }).mount(scope, cx);
```

---

## 2026-10-02: Signal-first props for Tree, Table, DataTable, Select, SelectHeadless, FileUpload; owned list signals (BREAKING)

**What changed.**

| Component | Before | After |
|---|---|---|
| Tree | `nodes` read once, `TreeNodeData.label_text`, selection / expansion held in `TreeState` (`selectedIds`, `toggleExpand`), `on_select: ?HandlerRef` (id via `invokeWithStr`), `selectable` / `on_expand` (never read), builder methods, result `{ wrapper, state }` | `nodes: Source([]const TreeNodeData)` (a new tree rebuilds the rows), `selected` / `expanded: Model([]const []const u8)` (sets of node ids), `on_select: ?Handler([]const u8)` receives the id, `TreeNodeData.label`; result `{ wrapper, selected, expanded }` |
| Table | `row_count: usize`, `on_sort` / `on_row_click: ?HandlerRef` (no payload), `TableState.setSort`, result `{ wrapper, state, vl_state }`, builder methods | `row_count: Source(usize)`, `data_version: Source(u64)` (change it when the cells change but the row count does not), `sort: Model(?TableSort)`, `on_sort_change: ?Handler(?TableSort)`, `on_row_click: ?Handler(usize)` receives the row; result `{ wrapper, sort }` |
| Select | `W.Select(props, scope, cx)`, `options` read once, `initial_selected: []const usize` (indices), `on_change: ?HandlerRef` (no payload), `disabled: bool`, result `{ wrapper, trigger, panel, state, is_open }` | `W.Select(props).mount(scope, cx)`; `options: Source(...)` (a new list rebuilds the rows), `value: Model(?[]const u8)` + `on_change: ?Handler(?[]const u8)` for `.single`, `values: Model([]const []const u8)` + `on_values_change` for `.multiple`, `open: Model(bool)` + `on_open_change`, `disabled: Source(bool)`; result `{ wrapper, trigger, panel, value, values, open }`; inner nodes for test hooks through `select.stateOf(result)` |
| SelectHeadless | `mountSelectHeadless(T, props, scope, cx)`, `initial_value`, `on_change: ?HandlerRef` (no payload), `disabled: bool`, `SelectProps` / `ControlledProp` on the state machine, result `{ …, is_open, state, item_nodes, vl_state }` | `SelectHeadless(T, props).mount(scope, cx)`; `options: Source(...)`, `value: Model(?T)` + `on_change: ?Handler(T)`, `open: Model(bool)` + `on_open_change`, `disabled: Source(bool)`; `TriggerSlotCtx` carries `value: Source(?T)` and `scope` so a custom trigger can follow the selection; result `{ wrapper, trigger, trigger_label, content, value, open }`; `SelectState(T){}` is the navigation state only |
| FileUpload | `W.FileUpload(props, scope, cx)`, files held in `state` (`addFile` / `removeSlot` / `fileCount`), `on_change` / `on_browse: ?HandlerRef`, `hint: []const u8`, result `{ wrapper, state }` | `W.FileUpload(props).mount(scope, cx)`; `files: Model([]const []const u8)` (paths; a bound signal must come from `scope.createList([]const u8, …)`), `on_change: ?Handler([]const []const u8)`, `on_browse: ?Handler(void)`, `hint: Source([]const u8)`; result `{ wrapper, files, drop_zone, rt }`; a custom Browse adds through `result.add(path)` |
| DataTable | `mountDataTable(props, scope, cx)` / `W.DataTable(props, scope, cx)`, `rows` read once, `on_selection_change: ?HandlerRef`, selection read through `state.selectedRows`, result `{ wrapper, state, filter_input }` | `W.DataTable(props).mount(scope, cx)`; `rows: Source(...)`, `selection: Model([]const usize)` (raw row indices), `page: Model(usize)`, `on_selection_change: ?Handler([]const usize)`, `on_page_change: ?Handler(usize)`; result `{ wrapper, selection, page, filter_input }` |

A signal bound to a set-valued Model (Tree `selected` / `expanded`, DataTable
`selection`, Select `values`, FileUpload `files`) must be created with `scope.createList(E, initial)`: the component
writes new sets from temporary buffers and the signal keeps its own copy.
Binding a plain `createSignal([]const E, ...)` fails mount with
`error.ListModelNotOwned`.

**Why.** Same as the other entries. Selection and sort are values the caller
can read, write and intercept (`ui.split`) instead of methods on a state
struct; handlers receive what changed.

**Migration.**

```zig
// before
const tree = try W.Tree(.{ .nodes = &files, .on_select = ui.Cx.strHandlerFrom(S, s, S.picked) }).mount(scope, cx);
var ids: [16][]const u8 = undefined;
const selected = ids[0..tree.state.selectedIds(&ids)];
const dt = try W.DataTable(.{ .columns = &cols, .rows = &rows, .selection_mode = .multi }, scope, cx);
var buf: [64]usize = undefined;
const picked = buf[0..dt.state.selectedRows(&buf)];

// after
const open_dirs = try scope.createList([]const u8, &.{ "src", "docs" });
const tree = try W.Tree(.{ .nodes = &files, .expanded = open_dirs, .on_select = cx.on(S, s, S.picked) }).mount(scope, cx);
const dt = try W.DataTable(.{ .columns = &cols, .rows = rows, .selection_mode = .multi }).mount(scope, cx);
const picked = dt.selection.?.peek(); // or read it in an effect / memo

// Select: indices -> values
// before
const prio = try W.Select(.{ .options = &priority_options, .initial_selected = &.{1} }, scope, cx);
// after
const prio = try W.Select(.{ .options = &priority_options, .value = "normal" }).mount(scope, cx);
```

---

## 2026-10-02: Signal-first props for display components; one entry point for every component (BREAKING)

**What changed.**

| Component | Before | After |
|---|---|---|
| Alert | `title: ?[]const u8`, `message: []const u8`, `variant`, builder methods, `on_close: ?HandlerRef` | `variant` / `title` / `message` are Source (dynamic messages update the live region), `on_close: ?Handler(void)` |
| Tag | `text`, `color` read once, builder methods | `text` / `color` are Source; `variant` / `size` stay structural |
| Chip | `variant: default / active / outline / disabled`, `label: []const u8`, `on_click` / `on_close: ?HandlerRef` | `variant: default / outline`; state moved to `selected: Source(bool)` and `disabled: Source(bool)`; `label` is Source; handlers are `?Handler(void)` |
| Breadcrumb | `on_click: ?HandlerRef` shared by every item (no way to tell which), `BreadcrumbItem.label_text` | `items: Source(...)` (a new path rebuilds the crumbs), `on_select: ?Handler([]const u8)` receives the item id, `BreadcrumbItem.label` |
| Timeline | `items` read once | `items: Source(...)` |
| Divider | `label_text: ?[]const u8`, builder methods | `label: Source([]const u8)` (empty = no label) |
| Markdown | `Markdown(text, opts).render(cx)` returning `{ root }` | `Markdown(.{ .text = Source, .options = ... }).mount(scope, cx)` returning the root node; a text signal re-renders |
| TabPanel | `TabPanel(.{ .id, .active: bool }).build(cx)` | `TabPanel(.{ .id, .active: Source(bool) }).mount(scope, cx)`, e.g. `.active = ui.eq(tab, "files")` |
| EditorTabs | — | **Removed.** It never wired its handlers; use `Tabs(.{ .variant = .tab, .closable = true })` |
| Spinner, Skeleton, Group, VStack, HStack, GlassBox | `X(props)` plus builder setters | `X(props)` only (anytype literal); builder setters removed |

**Why.** Same as the other entries: one way to pass values, and values that
change after mount are Sources.

**Migration.**

```zig
// before
const crumbs = try W.Breadcrumb(.{ .items = &items, .on_click = ui.Cx.handlerFrom(S, s, S.nav) }).mount(scope, cx);
const chip = try W.Chip(.{ .label = "Open", .variant = .active }).mount(scope, cx);
const spinner = try W.Spinner(.{}).size(24).mount(scope, cx);

// after
const crumbs = try W.Breadcrumb(.{ .items = path, .on_select = cx.on(S, s, S.goTo) }).mount(scope, cx);
const chip = try W.Chip(.{ .label = "Open", .selected = show_open }).mount(scope, cx);
const spinner = try W.Spinner(.{ .size = 24 }).mount(scope, cx);
```

## 2026-10-02: Signal-first props for Radio, RadioGroup, Modal, Sheet, Popover, Tabs, Accordion, Slider, Steps, Rate, NumberStepper, Card, Tooltip, Menu, DropdownMenu, Calendar, DatePicker, DateRangePicker (BREAKING)

**What changed.**

| Component | Before | After |
|---|---|---|
| RadioGroup | value read once at mount, `on_change: ?HandlerRef` (str payload), `RadioOption.label_text` | `value: Model(?[]const u8)`, `options` / `disabled: Source`, `on_change: ?Handler([]const u8)`; `RadioOption.label` |
| Radio | `on_change`, `name`, `value` (never wired), builder methods | display only: `checked` / `label` / `disabled` are Source |
| Modal / Sheet | `visible: ?*Signal(bool)`, builder `.visible(sig)` | `open: Model(bool)`, `on_open_change: ?Handler(bool)`; result field `open: ?*Signal(bool)` (null under `ui.split`); Modal `title` is Source |
| Popover | `visible` signal | `open: Model(bool)`, `on_open_change`; trigger click / hover only propose |
| AccordionItem | `expanded: bool` read once, `title: []const u8`, `on_change: ?HandlerRef`, `context`, builder `.title() .expanded() .variant() .onChange()`; `AccordionItemState.setExpanded / toggle` | `expanded: Model(bool)`, `title: Source([]const u8)`, `on_change: ?Handler(bool)` |
| Accordion | `exclusive: bool` (never took effect: items were never registered), `AccordionState` | `open: Model(?usize)`; mutually exclusive items take `.expanded = try acc.item(i)`; result field `open: ?*Signal(?usize)` |
| Slider | `initial_value` read once, `disabled: bool`, `haptic_feedback` / `haptic_pattern` mutated on `result.state`, `on_change: ?HandlerRef` (no payload, fired per pointer sample), builder methods; result `{ wrapper, state }` | `value: Model(f32)`, `disabled` / `haptic_feedback` / `haptic_pattern: Source`, `on_change: ?Handler(f32)` (landed value); result `{ wrapper, value: ?*Signal(f32) }` |
| Steps | `initial_current` read once (static rendering), builder methods | `current: Source(usize)`, `items: Source([]const StepItem)`; changes rebuild the steps |
| Rate | `value: f32` read once, `disabled: bool`, `on_change: ?HandlerRef` (no payload), builder methods, `result.state.setValue` | `value: Model(f32)`, `disabled: Source(bool)`, `on_change: ?Handler(f32)`; result `{ wrapper, value: ?*Signal(f32) }` |
| NumberStepper | `mountNumberStepper(props, scope, cx)`, `value: f64` read once, `disabled: bool`, `on_change: ?HandlerRef` (no payload), `result.state` | `NumberStepper(props).mount(scope, cx)` like every other component; `value: Model(f64)`, `disabled: Source(bool)`, `on_change: ?Handler(f64)`; result `{ wrapper, value: ?*Signal(f64) }` |
| Card | `selected: bool` read once, builder `.title() .subtitle() .variant() .interactive() .selected() .width() .height() .onClick()`, `on_click: ?HandlerRef` | `selected: Source(bool)`; `on_click: ?Handler(void)` (passing it makes the card interactive); builder methods removed |
| Tooltip | `text: []const u8`, builder `.text() .position() .offset()` | `text: Source([]const u8)` (dynamic text updates the tooltip and its a11y name); `open: Model(bool)` / `on_open_change` pass through to the Popover; result gains `open: ?*Signal(bool)` |
| Menu | `on_select: ?HandlerRef` without payload, `MenuItem.label_text`, builder methods, result `{ wrapper, trigger, state }` | `on_select: ?Handler([]const u8)` receives the item id; `open: Model(bool)` / `on_open_change`; `MenuItem.label`; result `{ wrapper, trigger, open }`; items are copied at mount |
| DropdownMenu | `DropdownItem.label_text`, builder methods, result `.state` (`is_open` signal) | `DropdownItem.label`; `open: Model(bool)` / `on_open_change`; result `{ wrapper, trigger, open }`. Choosing an item or Escape requests closing through the open pipeline, so a `ui.split` parent can keep the menu open |
| Calendar | `initial_year` / `initial_month` / `selected_date` read once, `on_select: ?HandlerRef` (no payload), builder methods, result `.state` | `value: Model(?SimpleDate)`, `month: Model(?YearMonth)` (null = follow the selection, else today), `on_select: ?Handler(SimpleDate)`; result `{ wrapper, value, month }` |
| DatePicker | `selected_date` / `initial_year` / `initial_month` read once, `on_change: ?HandlerRef`, `result.state` (`setSelectedDate`, `clearSelection`) | `value: Model(?SimpleDate)` (clear with `value.set(null)`), `on_change: ?Handler(SimpleDate)`; the popup calendar opens on the selected month (else today); result `{ wrapper, value }` |
| DateRangePicker | `start_date` / `end_date` / `initial_year` / `initial_month` read once, `on_change: ?HandlerRef`, `result.state` | `value: Model(?DateRange)`, `on_change: ?Handler(DateRange)`; the first click is a draft inside the component, so only complete ranges are proposed; the panel opens on the range's start month (else today); result `{ wrapper, value }` |
| Tabs | `active_id` / `default_active_id` read once, `on_change` / `on_close: ?HandlerRef`, `context`, `state_id`, `TabItem.label_text`, `TabsState` | `items: Source([]const TabItem)`, `active: Model(?[]const u8)`, `on_change` / `on_close: ?Handler([]const u8)`; `TabItem.label`; `TabsState` removed |

**Behavior to check.**

- A Modal / Sheet mounted without `open` starts **closed** (local `false`).
- Escape, outside click and the close button only *request* closing: the
  component proposes `open = false`; a `ui.split` parent can refuse and the
  overlay stays open. The exit animation starts after the value lands.
- Slider: user input is snapped to `step` and clamped to `[min, max]` before
  it is proposed; an out-of-range value written from outside is displayed
  clamped and is not written back. `on_change` fires once per landed value.
  The same holds for Rate and NumberStepper. The first user interaction on an
  out-of-range value proposes a clamped one, so `on_change` can report a value
  that differs from the stored one even though the display did not move.
- Tabs: `on_change` fires only for user changes that landed; setting the
  signal from code does not call it. Arrow keys skip disabled tabs. Strings in
  `items` stay owned by the caller and must stay valid while they are the
  source's current value.

**Migration.**

```zig
// before
const m = try W.Modal(.{ .title = "Delete?" }).visible(show).mount(scope, cx);
const tabs = try W.Tabs(.{ .items = &items, .default_active_id = "files",
    .on_change = ui.Cx.strHandlerFrom(S, s, S.tab) }).mount(scope, cx);

// after
const m = try W.Modal(.{ .title = "Delete?", .open = show }).mount(scope, cx);
const current = try scope.createSignal(?[]const u8, "files");
const tabs = try W.Tabs(.{ .items = &items, .active = current }).mount(scope, cx);
// programmatic switch: current.set("search");

// Accordion: one section open at a time
const acc = try W.Accordion(.{ .open = 0 }).mount(scope, cx);
for (titles, 0..) |title, i| {
    const it = try W.AccordionItem(.{ .title = title, .expanded = try acc.item(i) }).mount(scope, cx);
    try acc.container.appendChild(cx.allocator, it.item);
}
```

## 2026-10-02: Signal-first props for Checkbox, Switch, Button, Badge, StatusBadge, Progress (BREAKING)

**What changed.** These components take their props through `ui.reactive.props.coerce`
(docs/SIGNAL_API_DESIGN.md): any prop that can change accepts a literal, a
`*Signal(T)`, a `*Memo(T)` or a derived value; values the component writes back on interaction are a `Model` (a controlled value: the
component only proposes, the single source decides, the view follows the source).

| Component | Before | After |
|---|---|---|
| Checkbox | `initial_checked: bool`, `label_text: ?[]const u8`, `on_change: ?HandlerRef` (bool payload), builder `.checked() .label() .disabled() .onChange()`, `state_id` | `checked: Model(bool)` (`bool` / `*Signal(bool)` / `ui.split`), `label: Source([]const u8)`, `indeterminate` / `disabled: Source(bool)`, `on_change: ?Handler(bool)` |
| Switch | same as Checkbox | `checked: Model(bool)`, `label`, `disabled`, `on_change: ?Handler(bool)` |
| Button | `label: ?[]const u8`, builder `.label() .variant() .size() .disabled() .loading() .onClick()` | `label` / `variant` / `loading` / `disabled` are Source; builder methods removed |
| Badge | `text: ?[]const u8`, `count: ?u32`, builder methods | `text` / `count` / `status` / `dot` are Source |
| StatusBadge | `label_text` | `label` (Source), `status` (Source) |
| Progress | builder `.value() .status() …` | `value` / `status` are Source |

`on_change` now receives the value that actually landed (after a `ui.split`
parent transformed it) and fires only for user-initiated changes that changed
the value. Show / For / Match accept memos and derived values.

**Why.** Props were read once at mount; the only way to drive a mounted
component was imperative state access or remounting.

**Behavior to check.** Because props go through `anytype`, a few expressions
lose their result type: `@ptrCast(x)` (pass the pointer directly),
`if (c) .a else .b` (wrap in `@as(Enum, …)`), and decl literals inside a nested
literal such as `.style = .{ .height = .fixed(8) }` (name the type:
`core.StyleOverride{ … }`).

**Migration.**

```zig
// before
const cb = try W.Checkbox(.{ .label_text = "Agree", .initial_checked = true,
    .on_change = ui.Cx.boolHandlerFrom(S, s, S.changed) }).mount(scope, cx);
const btn = try W.Button(.{}).label("Save").disabled(true).mount(scope, cx);

// after
const agree = try scope.createSignal(bool, true);
const cb = try W.Checkbox(.{ .label = "Agree", .checked = agree,
    .on_change = cx.on(S, s, S.changed) }).mount(scope, cx);
const btn = try W.Button(.{ .label = "Save", .disabled = ui.not(agree) }).mount(scope, cx);
```

## 2026-10-01: reactive state only through Scope; host entry points batch (BREAKING)

**What changed.**

- `Cx.createSignal(T, v)` and `Cx.memo(T, ctx, f)` are removed. They allocated
  on the owner arena, could not be freed individually and lived until the `Cx`
  was destroyed. Use the `Scope` you were mounted with.
- The top-level `ui.createEffect` / `ui.createMemo` (owner-level free
  functions) are no longer re-exported. Use `scope.createEffect` /
  `scope.createMemo`. The owner-level primitives remain under `ui.reactive.*`
  as low-level API with no lifetime management.
- Every host entry point on `Cx` (`handleMouse*`, `handleKey*`, IME, scroll,
  magnify, drag, `handleCommand`, `cancelPointerInteractions`,
  `fireDueTimers`, `drainDeferredWork`) and every before-render / after-layout
  hook pass now runs inside an owner batch. Effects triggered by a handler run
  once, when the entry point returns, instead of once per `set()`.

**Why.** Two creation paths with different lifetimes got mixed; and a handler
that set three signals ran each dependent effect three times, two of them on
half-updated state.

**Behavior to check.** Inside a handler, an effect no longer runs synchronously
at `set()`. Code that sets a signal and then, in the same handler, reads a node
or value the effect would have updated now sees the old one. Read the signal
instead, or move the follow-up into the effect.

**Migration.**

```zig
// before
const open = try cx.createSignal(bool, false);
const total = try cx.memo(u32, .{ .a = a }, compute);
try ui.createEffect(cx.owner, ctx, run);

// after
const open = try scope.createSignal(bool, false);
const total = try scope.createMemo(u32, .{ .a = a }, compute);
try scope.createEffect(ctx, run);
```

## 2026-10-01: momentum phase and deterministic ScrollArea state (BREAKING)

**What changed.** `ScrollEvent.is_momentum: bool` is replaced by
`momentum: ui.events.MomentumPhase` (`none | began | changed | ended`); use
`scroll.isMomentum()`. `system_sdk.events.MouseWheel` gets the same field.

`ScrollState` no longer guesses gesture boundaries from frame counts. Removed:
`user_scrolling`, `scroll_idle_frames`, `scroll_event_idle_frames`,
`tail_idle_frames`, `momentum_idle_frames`, `has_scroll_history`,
`is_trackpad_session`, `awaiting_trackpad_reengage`, `phase_end_guard_frames`,
`suppress_outward_momentum_x/y`, `bounce_done_time_x/y`, and the tuning fields
`wheel_release_frames`, `trackpad_reengage_delta_threshold`,
`phase_end_guard_frames`, `idle_residual_delta_threshold`,
`momentum_bonus_tail_cutoff`. Added: `touching`, `momentum_active`,
`momentum_spent_x/y`, `input_serial` and `inputActive()`.

Behavior: a mouse wheel without gesture phases no longer rubber-bands (same as
NSScrollView). Momentum that reaches an edge bounces once; the rest of that
momentum stream does not push outward again. Losing window focus cancels an
in-progress gesture and momentum. A diagonal event on a `.both` ScrollArea that
can scroll only one of its axes goes to the layer of its dominant axis instead
of dropping the other component. `Notifier` cards are swiped by trackpad
gestures only: `ended` commits past the threshold, `cancelled` springs back,
and a mouse wheel no longer swipes (there was a 140 ms silence timeout before).

**Why.** The old state was released by timeouts, and several guards were
frame or millisecond windows. Begin/end signals now exist for gestures and
momentum, so the state follows them directly.

**Migration.**

```zig
// before
const active = ss.user_scrolling or ss.scroll_event_idle_frames <= ScrollState.scroll_tuning.wheel_release_frames;
const momentum = ss.momentum_idle_frames <= 2;
if (scroll.is_momentum) ...

// after
const active = ss.inputActive(); // gesture, momentum or scrollbar drag in progress
const scrolled_this_frame = ss.input_serial != last_seen_serial;
if (scroll.isMomentum()) ...
```

## 2026-10-01: scroll events carry the gesture phase (BREAKING)

**What changed.** `ui.events.ScrollEvent` replaces `phase_ended: bool` and
`is_trackpad: bool` with `phase: ui.events.ScrollPhase`
(`none | may_begin | began | changed | ended | cancelled`). Use
`scroll.phaseEnded()` (ended or cancelled) and `scroll.isTrackpad()` instead of
the old fields. `Cx.handleScrollEx` and `Cx.handleScrollWithModifiers` are
replaced by `Cx.handleScroll(ScrollEvent)` and `Cx.handleSdkWheel(MouseWheel)`.
The SystemSdk `mouse_wheel` event is now `system_sdk.events.MouseWheel` with a
`phase` field.

**Why.** Only `phase_ended` reached the dispatcher, so it could not tell when a
new trackpad gesture began. If an `ended` event was lost, every later trackpad
scroll went to the previous gesture's scroll area. `began` now starts a new
gesture deterministically, and `cancelled` releases it.

**Migration.**

```zig
// before
cx.handleScrollWithModifiers(e.x, e.y, e.dx, e.dy, e.is_momentum, e.phase_ended, e.is_trackpad, mods);
if (scroll.phase_ended) release();
if (scroll.is_trackpad) ...

// after
cx.handleSdkWheel(e); // e: system_sdk.events.MouseWheel
if (scroll.phaseEnded()) release();
if (scroll.isTrackpad()) ...
```

Test harness: `POST /scroll` without `phase` is now a mouse-wheel event. Send
trackpad gestures as a full sequence (`phase: "began"`, `"changed"`...,
`"ended"`), or use `trackpadScroll()` from `e2e/client.ts`.
