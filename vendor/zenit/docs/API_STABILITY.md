# zenit API Stability

zenit is pre-1.0. Breaking changes are recorded in [MIGRATION.md](MIGRATION.md).
The tiers below describe the proposed v1 surface, not a compatibility guarantee
for the current development version.

## Tiers

| Tier | Promise |
|---|---|
| **Stable** | Frozen at v1.0; breaking changes require a major. props structs may **gain new fields with defaults** (not a break). |
| **Unstable** | May break within a v1.x minor; changes are recorded in `docs/MIGRATION.md`. |
| **Internal** | No promise. Anything not re-exported at the top level of `ui` / `zenit_app` counts as Internal. |

## Stable (the v1 frozen surface)

### Runtime (`zenit_app`)
- `App.init / deinit / mount / runWith / run / quit / processEvents / maybeReconfigureSurface / frame`
- `App.Config` (`window` / `font` / `clear_color` / `pump_timeout_ms` / `frame_pacing` / `idle_wait_ms` / `idle_skip_frames`)
- `FrameStats` **existence and the getLastFrameStats() entry point** (the field set is under Unstable)

### View tree (`ui.view`, `ui.on`): the app-facing way to build UI
- `ui.view`: `render / mount`, elements `box / row / col / text / fmt / icon / spacer / with / component / attrs / setup / list / listWith / show (+ fallback) / match / each / eachWith`, style parts `when / hover / styleBy`
- `ui.on`: `set / toggle / update / assign / call / bind`
- `ViewParts` (the component protocol: `viewParts` on results, `viewMount` on builders)
- Element and style-part types (`Box`, `Text`, `When`, …) are Unstable: write elements through the functions above, not by naming their types (except in helper return types, see VIEW_DSL.md)

### Builders and core types (`ui`)
- Node-level builders, for code inside components: `box / hstack / vstack / text / textFmt / image / imageTint / svg / svgTint / icon / iconTint / spacer / clickable / grid`
- `Cx` (public method subset: `setTheme` / `themeSignal` / `bindState` / `on` / `setViewport` / `handleMouse* / handleKey*` event entries)
- `Node` (public methods such as `appendChild / removeChild / setText / getText / setStyle / markLayoutDirty / markRenderDirty`)
- `Scope` (`childScope / createSignal / createMemo / createEffect / registerResource / dispose`): the only app-facing way to create reactive state
- Style types: `Style / Color / Padding / Margin / Border / Outline / Sizing / Shadow / Gradient / CornerRadius / BlendMode / Direction / FlexWrap / TextWrap / CursorShape / TextProps / ImageProps`
- Reactivity: the `Signal / Memo` types (created through `Scope`); host entry points on `Cx` (events, timers, deferred work, before-render/after-layout hooks) batch signal writes
- Control flow: `Show / For / Match`
- Events: `HandlerRef` (the uniform widget-callback shape) / `EventCallback`
- Theming: `ui.theme.light / dark / high_contrast`; new `ThemeTokens` fields are allowed
- a11y props: `A11yRole / A11yProps`
- Icons: the `ui.system_icons.*` semantic set, `ui.icons.get`, the interface shape of
  `ui.icons.all / count`, and `ui.assets`. The concrete named constants of `ui.icons`
  belong to the selected provider's catalog; the same names across providers are not
  promised.

### widgets (`ui.widgets`, 44 components)
Button / Input / Textarea / Checkbox / Switch / Radio / Slider / SelectHeadless /
ComboBox / Badge / Tag / Chip / Card / Alert / Notifier / Progress / Spinner /
Skeleton / Timeline / Breadcrumb / Steps / Rate / Tabs / Accordion / Tree / Table /
DataTable / NumberStepper / TagsInput / FileUpload / Menu / Tooltip /
Popover / Modal / Sheet / Calendar / DatePicker / DateRangePicker / Markdown /
VirtualList / ScrollArea / Grid / Form / GlassBox

What is frozen: **the props struct + the mount entry signature + the existing fields of
the returned struct**.

## Unstable (explicitly exempted in v1)

- `ui.hit` (hit-test queries): bound to internal index structures
- `ui.path` (path geometry and mesh caching)
- `ui.devtools` / `ui.Inspector`
- `ui.a11y_tree` / `ui.a11y_router` / `ui.a11y_macos_bridge`
- `ui.gesture`
- The slot-customization surface of `ui.select_headless` (`render_trigger` / `render_item` ctx structs)
- The `FrameStats` field set
- DevTools presentation helpers, the recipe system (`ConditionalStyle` parsing details)
- `ui.fx`, `GlassParams / GlassSurface` (Liquid Glass is still iterating)
- `ui.control_flow` (exports beyond `Show/For/Match`)
- Fields labeled "internal" in mount results (e.g. `InputResult.state`)
- Harness developer entry points: `installHarnessClient` in `build.zig`, the installed
  TypeScript client API, and the file-RPC protocol (`-Dtest-mode=true` only; may evolve
  per minor; production builds do not provide this capability)
- Icon provider build entry points: the `icon-set` dependency option, `IconProvider`,
  `attachWithOptions`. Lucide is the public default; provider injection may evolve.

## Internal

- Everything in `ui.core` not re-exported at the top level (render_engine / lowering / layerize / hit_runtime …)
- `src/render`, `src/gpu`, `src/platform`, `src/system_sdk` (below the `App` abstraction)
- The `test_harness` Zig module and its queue/executor implementation (externally you
  only use the TypeScript facade above)

## Application API

Use `ui.view` to compose widgets and scope-owned signals for reactive state.
See [Signal-first props](SIGNAL_API_DESIGN.md) and [migration notes](MIGRATION.md)
for controlled values and callback conventions.

String payloads passed through `invokeWithStr` are valid only during the callback;
copy them if they must outlive it.

## Escape hatch

`Node.style.ensureExt()` and writing `behavior.events.*` directly are escape hatches
kept deliberately. What is Stable is the **existence** of the fields; deep
customization done through them is not protected by semver.

## Capabilities and limitations

### Bidirectional text editing (macOS)

The macOS configuration path hands the whole text to a single CoreText `CTLine`.
Static drawing, visual caret order in Input and Textarea, click hit-testing, cross-line
preferred-x, split selection rectangles, IME preedit, and the candidate-window caret all
read the `VisualLine` / `TextPosition+affinity` exported by that line; there is no
longer an assumption that "UTF-8 prefix width is monotonic in the logical offset". The
two carets that share one logical byte at a soft-wrap boundary or a bidi boundary are
distinguished by affinity. The selection/IME nodes of a standalone Textarea are
dynamically sized; long documents are no longer truncated at 16 rectangles, and the
composed display text is no longer truncated at 2048 bytes.

The boundary must be kept clear: `src/i18n/bidi.zig` is a complete Unicode 17.0.0
UAX #9 paragraph/line resolver (including isolates, explicit embedding/override,
brackets, L1/L2), gated by the official full `BidiTest.txt` and
`BidiCharacterTest.txt`; CoreText remains the authority for production glyph shaping,
fallback, run placement, and caret-x. CoreText results that are already in visual order
are not re-reordered by the framework. The framework's own UAX #9 resolver handles
portable text properties, paragraph base direction, deterministic mapping/tests, and
the non-CoreText layers; it does not replace the macOS shaper.

This is not physical acceptance complete: candidate windows under real
Arabic/Hebrew/CJK input sources, VoiceOver editing, and the storybook RTL pixel matrix
are still `NOT RUN` at the current release revision. The degraded path without a Font provider is still usable, but its
estimated coordinates are not part of the macOS production correctness claim.

### Grapheme clusters

`src/text_core/grapheme.zig` implements UAX #29 extended grapheme clusters
(GB1-GB999: CRLF / Hangul syllables / Extend / ZWJ / SpacingMark / Prepend /
ExtPict ZWJ sequences / Regional Indicator pairs / skin-tone modifiers).
All four boundary functions for caret movement, deletion, and selection go through it,
covering both single-line and multi-line paths.

⚠ The property tables are a **hand-written interval approximation**, not generated from
UCD: SpacingMark / Prepend for rare scripts may be missing, degrading to "one extra
break" (the caret stops one extra cell; it does not crash).
No legacy grapheme cluster definition and no ICU-style tailoring.

### Color emoji (macOS)

Color glyphs are detected from the font tables (sbix / COLR / CBDT +
`kCTFontTraitColorGlyphs`) and rasterized as BGRA premultiplied; the atlas gains BGRA8
pages coexisting with R8 grayscale pages (they share the page_index numbering; the
format is uniquely determined by the number); the shader branches on the per-instance
`is_color` flag: color output takes the sampled RGBA directly, without multiplying the
text color.

The decision is per **font**, not per code point: the same code point may still be
single-channel coverage in text-presentation (VS15) or in a monochrome font, and vice
versa. What determines the rasterization result is whichever font CoreText fallback
finally selects.

### Single-line Input length limit

The text limit of a single-line `Input` is `editable_block.MAX_INPUT_BYTES`
(currently **2048 bytes**). The canonical buffer is still inlined in `TextInputState`;
undo/redo snapshots are allocated dynamically to the current text length and freed by
the state, no longer copying the whole 2048-byte buffer. A failed snapshot allocation
is a transactional no-op and does not corrupt existing history. For long text use
`Textarea` (piece tree, no such limit).

### Drag and drop: platform capability in both directions implemented, full product acceptance not complete

**Supported** (2026-07-31): dragging files from Finder / the browser into the window.
Attach `on_drag_enter` / `on_drag_leave` / `on_drop` to any node and it becomes a drop
target:

```zig
node.behavior.events.on_drop =
    core.Cx.strHandlerFrom(MyState, state, MyState.onDrop);
// fn onDrop(self: *MyState, paths: []const u8) void
// paths = newline-separated path list; iterate with std.mem.splitScalar(u8, paths, '\n')
```

⚠ The `paths` slice is **valid only during the callback** (it points into the backend's
per-frame buffer); you must dupe it yourself if you need to keep it. This is the same general
rule as `invokeWithStr`.

Per-node enter/leave is synthesized by the framework from the position stream (the
platform only reports entered/exited at the **window** boundary), so dragging across
multiple targets inside the window delivers correct enter and exit to each of them.
The hint area of `FileUpload` is already a ready-made drop zone.

**Drag source implementation**: `SystemSdk.beginDrag` is wired to AppKit's
`beginDraggingSessionWithItems`, supporting text / file URL / internal payloads,
copy/move/link operations, preview/hotspot, and a completion token. It is currently a
platform-SDK capability; the widget layer does not yet provide a high-level hook for
"any node declares itself draggable", so applications must start the session from
pointer events themselves.

**Still not a production claim**: the real manual matrix for Finder drag-out,
cross-zenit-window drags, cancellation, operation negotiation, and source window
teardown has not been completed at the same release revision. mock/link tests only
prove that the contract and the bridge exist; they do not substitute for these
scenarios.

### Platforms

macOS uses Metal. This development branch also provides a Windows D3D12 backend;
see [Windows acceptance](WINDOWS_ACCEPTANCE.md) for build and runtime checks.
Linux remains experimental.
